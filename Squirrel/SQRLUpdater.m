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

NSString * const SQRLUpdaterUpdateAvailableNotification = @"SQRLUpdaterUpdateAvailableNotification";
NSString * const SQRLUpdaterUpdateAvailableNotificationDownloadedUpdateKey = @"SQRLUpdaterUpdateAvailableNotificationDownloadedUpdateKey";

NSString * const SQRLUpdaterErrorDomain = @"SQRLUpdaterErrorDomain";
const NSInteger SQRLUpdaterErrorMissingUpdateBundle = 2;
const NSInteger SQRLUpdaterErrorPreparingUpdateJob = 3;
const NSInteger SQRLUpdaterErrorRetrievingCodeSigningRequirement = 4;

@interface SQRLUpdater ()

@property (atomic, readwrite) SQRLUpdaterState state;

// A serial operation queue for update checks.
@property (nonatomic, strong, readonly) NSOperationQueue *updateQueue;

// A timer used to poll for updates.
@property (nonatomic, strong) NSTimer *updateTimer;

// The folder into which the latest update will be/has been downloaded.
@property (nonatomic, strong) NSURL *downloadFolder;

// The verifier used to check code against the running application's signature.
@property (nonatomic, strong, readonly) SQRLCodeSignatureVerifier *verifier;

@end

@implementation SQRLUpdater

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
	
	_updateQueue = [[NSOperationQueue alloc] init];
	self.updateQueue.maxConcurrentOperationCount = 1;
	self.updateQueue.name = @"com.github.Squirrel.updateCheckingQueue";

	_verifier = [[SQRLCodeSignatureVerifier alloc] init];
	if (_verifier == nil) return nil;
	
	return self;
}

- (void)dealloc {
	[_updateTimer invalidate];
}

#pragma mark Update Timer

- (void)setUpdateTimer:(NSTimer *)updateTimer {
	if (_updateTimer == updateTimer) return;

	[_updateTimer invalidate];
	_updateTimer = updateTimer;
}

- (void)startAutomaticChecksWithInterval:(NSTimeInterval)interval {
	dispatch_async(dispatch_get_main_queue(), ^{
		self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(checkForUpdates) userInfo:nil repeats:YES];
	});
}

#pragma mark Checking for Updates

- (void)checkForUpdates {
	NSParameterAssert(self.updateRequest != nil);

	if (getenv("DISABLE_UPDATE_CHECK") != NULL) return;
	
	if (self.state != SQRLUpdaterStateIdle) return; //We have a new update installed already, you crazy fool!
	self.state = SQRLUpdaterStateCheckingForUpdate;
	
	NSMutableURLRequest *request = [self.updateRequest mutableCopy];
	[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

	[NSURLConnection sendAsynchronousRequest:request queue:self.updateQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
		if (data == nil) {
			NSLog(@"No data received for request %@", request);
			
			[self finishAndSetIdle];
			return;
		}
		
		NSDictionary *JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
		if (response == nil || ![JSON isKindOfClass:NSDictionary.class]) { //No updates for us
			NSLog(@"Instead of update information, server returned:\n%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);

			[self finishAndSetIdle];
			return;
		}

		SQRLUpdate *update = [[SQRLUpdate alloc] initWithJSON:JSON];
		if (update == nil) {
			NSLog(@"Update JSON is invalid: %@", JSON);

			[self finishAndSetIdle];
			return;
		}

		NSFileManager *fileManager = NSFileManager.defaultManager;
		
		NSString *tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSRunningApplication.currentApplication.bundleIdentifier];
		NSError *directoryCreationError = nil;
		if (![fileManager createDirectoryAtURL:[NSURL fileURLWithPath:tempDirectory] withIntermediateDirectories:YES attributes:nil error:&directoryCreationError]) {
			NSLog(@"Could not create directory at %@: %@", tempDirectory, directoryCreationError.sqrl_verboseDescription);
			[self finishAndSetIdle];
			return;
		}
		
		char *tempDirectoryNameCString = strdup([tempDirectory stringByAppendingPathComponent:@"update.XXXXXXX"].fileSystemRepresentation);
		@onExit {
			free(tempDirectoryNameCString);
		};
		
		if (mkdtemp(tempDirectoryNameCString) == NULL) {
			NSLog(@"Could not create temporary directory. Bailing."); //this would be bad
			[self finishAndSetIdle];
			return;
		}
		
		self.downloadFolder = [NSURL fileURLWithPath:[fileManager stringWithFileSystemRepresentation:tempDirectoryNameCString length:strlen(tempDirectoryNameCString)] isDirectory:YES];
		
		NSURL *zipDownloadURL = update.updateURL;
		NSURL *zipOutputURL = [self.downloadFolder URLByAppendingPathComponent:zipDownloadURL.lastPathComponent];

		NSMutableURLRequest *zipDownloadRequest = [NSMutableURLRequest requestWithURL:zipDownloadURL];
		[zipDownloadRequest setValue:@"application/zip" forHTTPHeaderField:@"Accept"];
		[NSURLConnection sendAsynchronousRequest:zipDownloadRequest queue:self.updateQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
			if (response == nil) {
				NSLog(@"Error downloading zipped update at %@", zipDownloadURL);
				[self finishAndSetIdle];
				return;
			}
			
			if (![data writeToURL:zipOutputURL atomically:YES]) {
				NSLog(@"Error saved zipped update to %@", zipOutputURL);
				[self finishAndSetIdle];
				return;
			}
			
			NSLog(@"Download completed to: %@", zipOutputURL);
			self.state = SQRLUpdaterStateUnzippingUpdate;
			
			[[[[[[[SQRLZipArchiver
				unzipArchiveAtURL:zipOutputURL intoDirectoryAtURL:self.downloadFolder]
				then:^{
					return [self updateBundleMatchingCurrentApplicationInDirectory:self.downloadFolder];
				}]
				flattenMap:^(NSBundle *updateBundle) {
					return [[self.verifier
						verifyCodeSignatureOfBundle:updateBundle.bundleURL]
						then:^{
							SQRLDownloadedUpdate *downloadedUpdate = [[SQRLDownloadedUpdate alloc] initWithUpdate:update bundle:updateBundle];
							return [RACSignal return:downloadedUpdate];
						}];
				}]
				doNext:^(id _) {
					self.state = SQRLUpdaterStateAwaitingRelaunch;
				}]
				doError:^(NSError *error) {
					NSLog(@"Could not install update: %@", error.sqrl_verboseDescription);
					[self finishAndSetIdle];
				}]
				deliverOn:RACScheduler.mainThreadScheduler]
				subscribeNext:^(SQRLDownloadedUpdate *downloadedUpdate) {
					NSDictionary *userInfo = @{ SQRLUpdaterUpdateAvailableNotificationDownloadedUpdateKey: downloadedUpdate };
					[NSNotificationCenter.defaultCenter postNotificationName:SQRLUpdaterUpdateAvailableNotification object:self userInfo:userInfo];
				}];
		}];
		
		self.state = SQRLUpdaterStateDownloadingUpdate;
	}];
}

- (void)finishAndSetIdle {
	if (self.downloadFolder != nil) {
		NSError *deleteError = nil;
		if (![NSFileManager.defaultManager removeItemAtURL:self.downloadFolder error:&deleteError]) {
			NSLog(@"Error removing downloaded update at %@, error: %@", self.downloadFolder, deleteError.sqrl_verboseDescription);
		}
		
		self.downloadFolder = nil;
	}
	
	self.shouldRelaunch = NO;
	self.state = SQRLUpdaterStateIdle;
}

#pragma mark Installing Updates

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

- (RACSignal *)prepareUpdateForInstallation {
	if (self.state != SQRLUpdaterStateAwaitingRelaunch) return [RACSignal empty];

	NSURL *targetURL = NSRunningApplication.currentApplication.bundleURL;
	return [[[[[[[RACSignal
		zip:@[
			[self updateBundleMatchingCurrentApplicationInDirectory:self.downloadFolder],
			[self codeSigningRequirementData],
		] reduce:^(NSBundle *updateBundle, NSData *requirementData) {
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
					xpc_dictionary_set_string(wrappedMessage.object, SQRLUpdateBundleURLKey, updateBundle.bundleURL.absoluteString.UTF8String);
					xpc_dictionary_set_bool(wrappedMessage.object, SQRLShouldRelaunchKey, self.shouldRelaunch);
					xpc_dictionary_set_bool(wrappedMessage.object, SQRLWaitForConnectionKey, true);
					xpc_dictionary_set_data(wrappedMessage.object, SQRLCodeSigningRequirementKey, requirementData.bytes, requirementData.length);

					xpc_connection_resume(connection.object);
					return [self sendMessage:wrappedMessage overConnection:connection];
				}];
		}]
		flatten]
		initially:^{
			[NSProcessInfo.processInfo disableSuddenTermination];
		}]
		finally:^{
			[NSProcessInfo.processInfo enableSuddenTermination];
		}]
		doError:^(NSError *error) {
			[self finishAndSetIdle];
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
