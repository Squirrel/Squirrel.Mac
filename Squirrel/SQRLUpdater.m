//
//  SQRLUpdater.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdater.h"
#import "NSBundle+SQRLVersionExtensions.h"
#import "NSError+SQRLVerbosityExtensions.h"
#import "NSProcessInfo+SQRLVersionExtensions.h"
#import "SQRLArguments.h"
#import "SQRLCodeSignatureVerifier.h"
#import "SQRLDownloadedUpdate.h"
#import "SQRLShipItLauncher.h"
#import "SQRLUpdate+Private.h"
#import "SQRLXPCObject.h"
#import "SQRLZipArchiver.h"
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>

NSString * const SQRLUpdaterErrorDomain = @"SQRLUpdaterErrorDomain";
NSString * const SQRLUpdaterServerDataErrorKey = @"SQRLUpdaterServerDataErrorKey";
NSString * const SQRLUpdaterJSONObjectErrorKey = @"SQRLUpdaterJSONObjectErrorKey";

const NSInteger SQRLUpdaterErrorMissingUpdateBundle = 2;
const NSInteger SQRLUpdaterErrorPreparingUpdateJob = 3;
const NSInteger SQRLUpdaterErrorRetrievingCodeSigningRequirement = 4;
const NSInteger SQRLUpdaterErrorInvalidServerResponse = 5;
const NSInteger SQRLUpdaterErrorInvalidJSON = 6;

@interface SQRLUpdater ()

// The verifier used to check code against the running application's signature.
@property (nonatomic, strong, readonly) SQRLCodeSignatureVerifier *verifier;

@end

@implementation SQRLUpdater

#pragma mark Properties

- (RACSignal *)updates {
	return [[self.checkForUpdatesCommand.executionSignals
		concat]
		setNameWithFormat:@"%@ -updates", self];
}

#pragma mark Lifecycle

- (id)init {
	NSAssert(NO, @"Use -initWithUpdateRequest: instead");
	return nil;
}

- (id)initWithUpdateRequest:(NSURLRequest *)updateRequest {
	NSParameterAssert(updateRequest != nil);

	self = [super init];
	if (self == nil) return nil;

	_updateRequest = [updateRequest copy];

	_verifier = [[SQRLCodeSignatureVerifier alloc] init];
	if (_verifier == nil) return nil;

	BOOL updatesDisabled = (getenv("DISABLE_UPDATE_CHECK") != NULL);

	@weakify(self);
	_checkForUpdatesCommand = [[RACCommand alloc] initWithEnabled:[RACSignal return:@(!updatesDisabled)] signalBlock:^(id _) {
		@strongify(self);
		NSParameterAssert(self.updateRequest != nil);

		// TODO: Maybe allow this to be an argument to the command?
		NSMutableURLRequest *request = [self.updateRequest mutableCopy];
		[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

		return [[[[[[NSURLConnection
			rac_sendAsynchronousRequest:request]
			reduceEach:^(id _, NSData *data) {
				return data;
			}]
			flattenMap:^(NSData *data) {
				return [self updateFromJSONData:data];
			}]
			flattenMap:^(SQRLUpdate *update) {
				return [self downloadAndInstallUpdate:update];
			}]
			doError:^(id _) {
				self.shouldRelaunch = NO;
			}]
			deliverOn:RACScheduler.mainThreadScheduler];
	}];
	
	return self;
}

#pragma mark Checking for Updates

- (RACDisposable *)startAutomaticChecksWithInterval:(NSTimeInterval)interval {
	@weakify(self);

	return [[[[[RACSignal
		interval:interval onScheduler:[RACScheduler schedulerWithPriority:RACSchedulerPriorityBackground]]
		flattenMap:^(id _) {
			@strongify(self);
			return [[self.checkForUpdatesCommand
				execute:RACUnit.defaultUnit]
				catch:^(NSError *error) {
					NSLog(@"Error checking for updates: %@", error);
					return [RACSignal empty];
				}];
		}]
		takeUntil:self.rac_willDeallocSignal]
		publish]
		connect];
}

- (RACSignal *)updateFromJSONData:(NSData *)data {
	NSParameterAssert(data != nil);

	return [[RACSignal startLazilyWithScheduler:[RACScheduler schedulerWithPriority:RACSchedulerPriorityBackground] block:^(id<RACSubscriber> subscriber) {
		NSError *error = nil;
		NSDictionary *JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
		if (JSON == nil) {
			NSMutableDictionary *userInfo = [error.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
			userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Update check failed", nil);
			userInfo[NSLocalizedRecoverySuggestionErrorKey] = NSLocalizedString(@"The server sent an invalid response. Try again later.", nil);
			userInfo[SQRLUpdaterServerDataErrorKey] = data;
			if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

			[subscriber sendError:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidServerResponse userInfo:userInfo]];
			return;
		}

		SQRLUpdate *update = nil;
		if ([JSON isKindOfClass:NSDictionary.class]) update = [[SQRLUpdate alloc] initWithJSON:JSON];

		if (update == nil) {
			NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
			userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Update check failed", nil);
			userInfo[NSLocalizedRecoverySuggestionErrorKey] = NSLocalizedString(@"The server sent an invalid JSON response. Try again later.", nil);
			userInfo[SQRLUpdaterJSONObjectErrorKey] = JSON;

			[subscriber sendError:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidJSON userInfo:userInfo]];
			return;
		}

		[subscriber sendNext:update];
		[subscriber sendCompleted];
	}] setNameWithFormat:@"-updateFromJSONData:"];
}

- (RACSignal *)downloadAndInstallUpdate:(SQRLUpdate *)update {
	NSParameterAssert(update != nil);

	return [[[self
		uniqueTemporaryDirectoryForUpdate]
		flattenMap:^(NSURL *downloadFolder) {
			return [[[self
				downloadBundleForUpdate:update intoFolder:downloadFolder]
				flattenMap:^(NSBundle *updateBundle) {
					return [self verifyAndInstallUpdate:update fromBundle:updateBundle];
				}]
				doError:^(id _) {
					NSError *error = nil;
					if (![NSFileManager.defaultManager removeItemAtURL:downloadFolder error:&error]) {
						NSLog(@"Error removing temporary download folder at %@: %@", downloadFolder, error.sqrl_verboseDescription);
					}
				}];
		}]
		setNameWithFormat:@"-downloadAndInstallUpdate: %@", update];
}

- (RACSignal *)downloadBundleForUpdate:(SQRLUpdate *)update intoFolder:(NSURL *)downloadFolder {
	NSParameterAssert(update != nil);
	NSParameterAssert(downloadFolder != nil);
	
	NSURL *zipDownloadURL = update.updateURL;
	NSMutableURLRequest *zipDownloadRequest = [NSMutableURLRequest requestWithURL:zipDownloadURL];
	[zipDownloadRequest setValue:@"application/zip" forHTTPHeaderField:@"Accept"];

	return [[[[[[[NSURLConnection
		rac_sendAsynchronousRequest:zipDownloadRequest]
		reduceEach:^(id _, NSData *data) {
			return data;
		}]
		flattenMap:^(NSData *data) {
			NSURL *zipOutputURL = [downloadFolder URLByAppendingPathComponent:zipDownloadURL.lastPathComponent];

			NSError *error = nil; 
			if ([data writeToURL:zipOutputURL options:NSDataWritingAtomic error:&error]) {
				return [RACSignal return:zipOutputURL];
			} else {
				return [RACSignal error:error];
			}
		}]
		doNext:^(NSURL *zipOutputURL) {
			NSLog(@"Download completed to: %@", zipOutputURL);
		}]
		flattenMap:^(NSURL *zipOutputURL) {
			return [SQRLZipArchiver unzipArchiveAtURL:zipOutputURL intoDirectoryAtURL:downloadFolder];
		}]
		then:^{
			return [self updateBundleMatchingCurrentApplicationInDirectory:downloadFolder];
		}]
		setNameWithFormat:@"-downloadBundleForUpdate: %@ intoFolder: %@", update, downloadFolder];
}

#pragma mark File Management

- (RACSignal *)uniqueTemporaryDirectoryForUpdate {
	return [[RACSignal startLazilyWithScheduler:[RACScheduler schedulerWithPriority:RACSchedulerPriorityBackground] block:^(id<RACSubscriber> subscriber) {
		// TODO: Use SQRLInstaller's temporary directory logic?
		NSURL *temporaryDirectoryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:NSRunningApplication.currentApplication.bundleIdentifier];

		NSError *error = nil;
		if (![NSFileManager.defaultManager createDirectoryAtURL:temporaryDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error]) {
			[subscriber sendError:error];
			return;
		}
		
		NSURL *updateDirectoryTemplate = [temporaryDirectoryURL URLByAppendingPathComponent:@"update.XXXXXXX"];
		char *updateDirectoryCString = strdup(updateDirectoryTemplate.path.fileSystemRepresentation);
		@onExit {
			free(updateDirectoryCString);
		};
		
		if (mkdtemp(updateDirectoryCString) == NULL) {
			int code = errno;

			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Could not create temporary directory", nil),
				NSURLErrorKey: updateDirectoryTemplate
			};

			[subscriber sendError:[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:userInfo]];
			return;
		}

		NSString *updateDirectoryPath = [NSFileManager.defaultManager stringWithFileSystemRepresentation:updateDirectoryCString length:strlen(updateDirectoryCString)];
		[subscriber sendNext:[NSURL fileURLWithPath:updateDirectoryPath isDirectory:YES]];
		[subscriber sendCompleted];
	}] setNameWithFormat:@"-uniqueTemporaryDirectoryForUpdate"];
}

- (RACSignal *)updateBundleMatchingCurrentApplicationInDirectory:(NSURL *)directory {
	NSParameterAssert(directory != nil);

	NSString *bundleIdentifier = NSRunningApplication.currentApplication.bundleIdentifier;
	return [[[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			NSFileManager *manager = [[NSFileManager alloc] init];
			NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:directory includingPropertiesForKeys:@[ NSURLTypeIdentifierKey ] options:NSDirectoryEnumerationSkipsPackageDescendants | NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^(NSURL *URL, NSError *error) {
				NSLog(@"Error enumerating item %@ within directory %@: %@", URL, directory, error);
				return YES;
			}];
			
			NSURL *updateBundleURL = [enumerator.rac_sequence objectPassingTest:^(NSURL *URL) {
				NSString *type = nil;
				NSError *error = nil;
				if (![URL getResourceValue:&type forKey:NSURLTypeIdentifierKey error:&error]) {
					NSLog(@"Error retrieving UTI for item at %@: %@", URL, error);
					return NO;
				}

				if (!UTTypeConformsTo((__bridge CFStringRef)type, kUTTypeApplicationBundle)) return NO;

				NSBundle *bundle = [NSBundle bundleWithURL:URL];
				if (bundle == nil) {
					NSLog(@"Could not open application bundle at %@", URL);
					return NO;
				}

				return [bundle.bundleIdentifier isEqual:bundleIdentifier];
			}];

			if (updateBundleURL != nil) {
				[subscriber sendNext:updateBundleURL];
				[subscriber sendCompleted];
			} else {
				NSDictionary *userInfo = @{
					NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not locate update bundle for %@ within %@", nil), NSRunningApplication.currentApplication.bundleIdentifier, directory],
				};

				[subscriber sendError:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorMissingUpdateBundle userInfo:userInfo]];
			}

			return nil;
		}]
		map:^(NSURL *URL) {
			return [NSBundle bundleWithURL:URL];
		}]
		setNameWithFormat:@"-applicationBundleMatchingCurrentApplicationInDirectory: %@", directory];
}

- (NSURL *)applicationSupportURL {
	NSString *path = nil;
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
	path = (paths.count > 0 ? paths[0] : NSTemporaryDirectory());
	
	NSString *appDirectoryName = NSBundle.mainBundle.bundleIdentifier;
	NSURL *appSupportURL = [[NSURL fileURLWithPath:path] URLByAppendingPathComponent:appDirectoryName];
	
	NSFileManager *fileManager = [[NSFileManager alloc] init];

	NSError *error = nil;
	BOOL success = [fileManager createDirectoryAtPath:appSupportURL.path withIntermediateDirectories:YES attributes:nil error:&error];
	if (!success) {
		NSLog(@"Error creating Application Support folder: %@", error.sqrl_verboseDescription);
	}
	
	return appSupportURL;
}

#pragma mark Installing Updates

- (RACSignal *)codeSigningRequirementData {
	return [[RACSignal defer:^{
		NSData *requirementData = self.verifier.requirementData;
		if (requirementData != nil) {
			return [RACSignal return:requirementData];
		} else {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not load code signing requirement for %@", nil), NSRunningApplication.currentApplication.bundleIdentifier],
			};

			return [RACSignal error:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorRetrievingCodeSigningRequirement userInfo:userInfo]];
		}
	}] setNameWithFormat:@"-codeSigningRequirementData"];
}

- (RACSignal *)verifyAndInstallUpdate:(SQRLUpdate *)update fromBundle:(NSBundle *)updateBundle {
	NSParameterAssert(update != nil);
	NSParameterAssert(updateBundle != nil);

	return [[[[self.verifier
		verifyCodeSignatureOfBundle:updateBundle.bundleURL]
		then:^{
			SQRLDownloadedUpdate *downloadedUpdate = [[SQRLDownloadedUpdate alloc] initWithUpdate:update bundle:updateBundle];
			return [RACSignal return:downloadedUpdate];
		}]
		flattenMap:^(SQRLDownloadedUpdate *downloadedUpdate) {
			return [self prepareUpdateForInstallation:downloadedUpdate];
		}]
		setNameWithFormat:@"-verifyAndInstallUpdate: %@ fromBundle: %@", update, updateBundle];
}

- (RACSignal *)prepareUpdateForInstallation:(SQRLDownloadedUpdate *)update {
	NSURL *targetURL = NSRunningApplication.currentApplication.bundleURL;
	return [[[[[[self
		codeSigningRequirementData]
		flattenMap:^(NSData *requirementData) {
			NSNumber *targetWritable = nil;
			NSError *targetWritableError = nil;
			BOOL gotWritable = [targetURL getResourceValue:&targetWritable forKey:NSURLIsWritableKey error:&targetWritableError];

			return [[SQRLShipItLauncher
				// If we can't determine whether it can be written, assume nonprivileged and
				// wait for another, more canonical error.
				launchPrivileged:(gotWritable && !targetWritable.boolValue)]
				flattenMap:^(SQRLXPCObject *connection) {
					xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);

					SQRLXPCObject *wrappedMessage = [[SQRLXPCObject alloc] initWithXPCObject:message];
					xpc_release(message);

					xpc_dictionary_set_string(wrappedMessage.object, SQRLShipItCommandKey, SQRLShipItInstallCommand);
					xpc_dictionary_set_string(wrappedMessage.object, SQRLTargetBundleURLKey, targetURL.absoluteString.UTF8String);
					xpc_dictionary_set_string(wrappedMessage.object, SQRLUpdateBundleURLKey, update.bundle.bundleURL.absoluteString.UTF8String);
					xpc_dictionary_set_bool(wrappedMessage.object, SQRLShouldRelaunchKey, self.shouldRelaunch);
					xpc_dictionary_set_bool(wrappedMessage.object, SQRLWaitForConnectionKey, true);
					xpc_dictionary_set_data(wrappedMessage.object, SQRLCodeSigningRequirementKey, requirementData.bytes, requirementData.length);

					xpc_connection_resume(connection.object);
					return [self sendMessage:wrappedMessage overConnection:connection];
				}];
		}]
		initially:^{
			[NSProcessInfo.processInfo disableSuddenTermination];
		}]
		finally:^{
			[NSProcessInfo.processInfo enableSuddenTermination];
		}]
		replay]
		setNameWithFormat:@"-prepareUpdateForInstallation"];
}

- (RACSignal *)sendMessage:(SQRLXPCObject *)message overConnection:(SQRLXPCObject *)connection {
	NSParameterAssert(message != nil);
	NSParameterAssert(connection != nil);

	return [[[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			xpc_connection_send_message_with_reply(connection.object, message.object, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(xpc_object_t reply) {
				if (xpc_dictionary_get_bool(reply, SQRLShipItSuccessKey)) {
					SQRLXPCObject *wrappedReply = [[SQRLXPCObject alloc] initWithXPCObject:reply];
					[subscriber sendNext:wrappedReply];
					[subscriber sendCompleted];
				} else {
					const char *errorStr = xpc_dictionary_get_string(reply, SQRLShipItErrorKey);
					NSDictionary *userInfo = @{
						NSLocalizedDescriptionKey: @(errorStr) ?: NSLocalizedString(@"An unknown error occurred within ShipIt", nil),
					};

					[subscriber sendError:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorPreparingUpdateJob userInfo:userInfo]];
				}
			});
			
			return nil;
		}]
		replay]
		setNameWithFormat:@"-sendMessage: %@ overConnection: %@", message, connection];
}

@end
