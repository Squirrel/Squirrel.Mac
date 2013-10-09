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
#import "RACSignal+SQRLTransactionExtensions.h"
#import "SQRLCodeSignature.h"
#import "SQRLDirectoryManager.h"
#import "SQRLDownloadedUpdate.h"
#import "SQRLShipItLauncher.h"
#import "SQRLShipItState.h"
#import "SQRLUpdate+Private.h"
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

// The code signature for the running application, used to check updates before
// sending them to ShipIt.
@property (nonatomic, strong, readonly) SQRLCodeSignature *signature;

// Lazily launches ShipIt upon first subscription.
//
// Sends completed or error.
@property (nonatomic, strong, readonly) RACSignal *shipItLauncher;

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

	_signature = [SQRLCodeSignature currentApplicationSignature];
	if (_signature == nil) return nil;

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

	_shipItLauncher = [[[RACSignal
		defer:^{
			NSURL *targetURL = NSRunningApplication.currentApplication.bundleURL;

			NSNumber *targetWritable = nil;
			NSError *targetWritableError = nil;
			BOOL gotWritable = [targetURL getResourceValue:&targetWritable forKey:NSURLIsWritableKey error:&targetWritableError];

			// If we can't determine whether it can be written, assume nonprivileged and
			// wait for another, more canonical error.
			return [SQRLShipItLauncher launchPrivileged:(gotWritable && !targetWritable.boolValue)];
		}]
		replayLazily]
		setNameWithFormat:@"shipItLauncher"];
	
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
		error = nil;
		if ([JSON isKindOfClass:NSDictionary.class]) update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:JSON error:&error];

		if (update == nil) {
			NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
			userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Update check failed", nil);
			userInfo[NSLocalizedRecoverySuggestionErrorKey] = NSLocalizedString(@"The server sent an invalid JSON response. Try again later.", nil);
			userInfo[SQRLUpdaterJSONObjectErrorKey] = JSON;
			if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

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
	SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];

	return [[[directoryManager
		applicationSupportURL]
		flattenMap:^(NSURL *appSupportURL) {
			NSURL *updateDirectoryTemplate = [appSupportURL URLByAppendingPathComponent:@"update.XXXXXXX"];
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

				return [RACSignal error:[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:userInfo]];
			}

			NSString *updateDirectoryPath = [NSFileManager.defaultManager stringWithFileSystemRepresentation:updateDirectoryCString length:strlen(updateDirectoryCString)];
			return [RACSignal return:[NSURL fileURLWithPath:updateDirectoryPath isDirectory:YES]];
		}]
		setNameWithFormat:@"-uniqueTemporaryDirectoryForUpdate"];
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

#pragma mark Installing Updates

- (RACSignal *)verifyAndInstallUpdate:(SQRLUpdate *)update fromBundle:(NSBundle *)updateBundle {
	NSParameterAssert(update != nil);
	NSParameterAssert(updateBundle != nil);

	return [[[[self.signature
		verifyBundleAtURL:updateBundle.bundleURL]
		then:^{
			SQRLDownloadedUpdate *downloadedUpdate = [[SQRLDownloadedUpdate alloc] initWithUpdate:update bundle:updateBundle];
			return [RACSignal return:downloadedUpdate];
		}]
		flattenMap:^(SQRLDownloadedUpdate *downloadedUpdate) {
			return [[self prepareUpdateForInstallation:downloadedUpdate] then:^{
				return [RACSignal return:downloadedUpdate];
			}];
		}]
		setNameWithFormat:@"-verifyAndInstallUpdate: %@ fromBundle: %@", update, updateBundle];
}

- (RACSignal *)prepareUpdateForInstallation:(SQRLDownloadedUpdate *)update {
	NSParameterAssert(update != nil);

	return [[[[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];
			return [[[[SQRLShipItState
				readUsingDirectoryManager:directoryManager]
				catchTo:[RACSignal empty]]
				flattenMap:^(SQRLShipItState *existingState) {
					if (existingState.installerState != SQRLInstallerStateNothingToDo) {
						// If this happens, shit is crazy, because it implies that an
						// update is being installed over us right now.
						NSDictionary *userInfo = @{
							NSLocalizedDescriptionKey: NSLocalizedString(@"Installation in progress", nil),
							NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"An update for %@ is already in progress.", nil), NSRunningApplication.currentApplication.bundleIdentifier],
						};

						return [RACSignal error:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorPreparingUpdateJob userInfo:userInfo]];
					}

					return [RACSignal empty];
				}]
				then:^{
					SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:NSRunningApplication.currentApplication.bundleURL updateBundleURL:update.bundle.bundleURL bundleIdentifier:NSRunningApplication.currentApplication.bundleIdentifier codeSignature:self.signature];
					state.relaunchAfterInstallation = self.shouldRelaunch;
					return [state writeUsingDirectoryManager:directoryManager];
				}];
		}]
		then:^{
			return self.shipItLauncher;
		}]
		sqrl_addTransactionWithName:NSLocalizedString(@"Preparing update", nil) description:NSLocalizedString(@"An update for %@ is being prepared. Interrupting the process could corrupt the application.", nil), NSRunningApplication.currentApplication.bundleIdentifier]
		setNameWithFormat:@"-prepareUpdateForInstallation: %@", update];
}

@end
