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
#import "SQRLShipItConnection.h"
#import "SQRLShipItRequest.h"
#import "SQRLUpdate.h"
#import "SQRLZipArchiver.h"
#import "SQRLShipItRequest.h"
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
const NSInteger SQRLUpdaterErrorInvalidServerBody = 7;

// The prefix used when creating temporary directories for updates. This will be
// followed by a random string of characters.
static NSString * const SQRLUpdaterUniqueTemporaryDirectoryPrefix = @"update.";

@interface SQRLUpdater ()

@property (atomic, readwrite) SQRLUpdaterState state;

// The code signature for the running application, used to check updates before
// sending them to ShipIt.
@property (nonatomic, strong, readonly) SQRLCodeSignature *signature;

// When executed with an `SQRLShipItState`, launches ShipIt.
@property (nonatomic, strong, readonly) RACCommand *shipItLauncher;

// Lazily removes outdated temporary directories (used for previous updates)
// upon first subscription.
//
// Pruning directories while an update is pending or in progress will result in
// undefined behavior.
//
// Sends each removed directory then completes, or errors, on an unspecified
// thread.
@property (nonatomic, strong, readonly) RACSignal *prunedUpdateDirectories;

// Parses an update model from downloaded data.
//
// data - JSON data representing an update manifest. This must not be nil.
//
// Returns a signal which synchronously sends a `SQRLUpdate` then completes, or
// errors.
- (RACSignal *)updateFromJSONData:(NSData *)data;

// Downloads an update bundle and prepares it for installation.
//
// Upon success, the update will be automatically installed after the
// application terminates.
//
// update - Describes the update to download and prepare. This must not be nil.
//
// Returns a signal which sends a `SQRLDownloadedUpdate` then completes, or
// errors, on a background thread.
- (RACSignal *)downloadAndPrepareUpdate:(SQRLUpdate *)update;

// Downloads the archived bundle associated with the given update.
//
// update            - Describes the update to install. This must not be nil.
// downloadDirectory - A directory in which to create a temporary directory for this
//                     download. This must not be nil.
//
// Returns a signal which sends an unarchived `NSBundle` then completes, or
// errors, on a background thread.
- (RACSignal *)downloadBundleForUpdate:(SQRLUpdate *)update intoDirectory:(NSURL *)downloadDirectory;

// Creates a unique directory in which to save the update bundle, for later use
// by ShipIt.
//
// Returns a signal which sends an `NSURL` then completes, or errors, on an
// unspecified thread.
- (RACSignal *)uniqueTemporaryDirectoryForUpdate;

// Recursively searches the given directory for an application bundle that has
// the same identifier as the running application.
//
// directory - The directory in which to search. This must not be nil.
//
// Returns a signal which synchronously sends an `NSBundle` then completes, or
// errors.
- (RACSignal *)updateBundleMatchingCurrentApplicationInDirectory:(NSURL *)directory;

// Validates the code signature of the given update bundle, then prepares it for
// installation.
//
// Upon success, the update will be automatically installed after the
// application terminates.
//
// update - Describes the update to verify and prepare. This must not be nil.
//
// Returns a signal which sends a `SQRLDownloadedUpdate` then completes, or
// errors, on a background thread.
- (RACSignal *)verifyAndPrepareUpdate:(SQRLUpdate *)update fromBundle:(NSBundle *)updateBundle;

// Prepares the given update for installation.
//
// Upon success, the update will be automatically installed after the
// application terminates.
//
// update - Describes the update and bundle to prepare. This must not be nil.
//
// Returns a signal which completes or errors on a background thread.
- (RACSignal *)prepareUpdateForInstallation:(SQRLDownloadedUpdate *)update;

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
	_updateClass = SQRLUpdate.class;

	NSError *error = nil;
	_signature = [SQRLCodeSignature currentApplicationSignature:&error];
	if (_signature == nil) {
#if DEBUG
		NSLog(@"Could not get code signature for running application, application updates are disabled: %@", error);
		return nil;
#else
		NSDictionary *exceptionInfo = @{ NSUnderlyingErrorKey: error };
		@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Could not get code signature for running application" userInfo:exceptionInfo];
#endif
	}

	BOOL updatesDisabled = (getenv("DISABLE_UPDATE_CHECK") != NULL);
	@weakify(self);

	_prunedUpdateDirectories = [[[[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItConnection.shipItJobLabel];
			return [directoryManager applicationSupportURL];
		}]
		flattenMap:^(NSURL *appSupportURL) {
			NSFileManager *manager = [[NSFileManager alloc] init];
			NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:appSupportURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsSubdirectoryDescendants errorHandler:^(NSURL *URL, NSError *error) {
				NSLog(@"Error enumerating item %@ within directory %@: %@", URL, appSupportURL, error);
				return YES;
			}];

			return [[enumerator.rac_sequence.signal
				filter:^(NSURL *enumeratedURL) {
					NSString *name = enumeratedURL.lastPathComponent;
					return [name hasPrefix:SQRLUpdaterUniqueTemporaryDirectoryPrefix];
				}]
				doNext:^(NSURL *directoryURL) {
					NSError *error = nil;
					if (![manager removeItemAtURL:directoryURL error:&error]) {
						NSLog(@"Error removing old update directory at %@: %@", directoryURL, error.sqrl_verboseDescription);
					}
				}];
		}]
		replayLazily]
		setNameWithFormat:@"%@ -prunedUpdateDirectories", self];

	_checkForUpdatesCommand = [[RACCommand alloc] initWithEnabled:[RACSignal return:@(!updatesDisabled)] signalBlock:^(id _) {
		@strongify(self);
		NSParameterAssert(self.updateRequest != nil);

		// TODO: Maybe allow this to be an argument to the command?
		NSMutableURLRequest *request = [self.updateRequest mutableCopy];
		[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

		// Prune old updates before the first update check.
		return [[[[[[[[self.prunedUpdateDirectories
			catch:^(NSError *error) {
				NSLog(@"Error pruning old updates: %@", error);
				return [RACSignal empty];
			}]
			then:^{
				self.state = SQRLUpdaterStateCheckingForUpdate;

				return [NSURLConnection rac_sendAsynchronousRequest:request];
			}]
			reduceEach:^(NSURLResponse *response, NSData *bodyData) {
				if ([response isKindOfClass:NSHTTPURLResponse.class]) {
					NSHTTPURLResponse *httpResponse = (id)response;
					if (!(httpResponse.statusCode >= 200 && httpResponse.statusCode <= 299)) {
						NSDictionary *errorInfo = @{
							NSLocalizedDescriptionKey: NSLocalizedString(@"Update check failed", nil),
							NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"The server sent an invalid response. Try again later.", nil),
							SQRLUpdaterServerDataErrorKey: bodyData,
						};
						NSError *error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidServerResponse userInfo:errorInfo];
						return [RACSignal error:error];
					}

					if (httpResponse.statusCode == 204 /* No Content */) {
						return [RACSignal empty];
					}
				}

				return [RACSignal return:bodyData];
			}]
			flatten]
			flattenMap:^(NSData *data) {
				return [self updateFromJSONData:data];
			}]
			flattenMap:^(SQRLUpdate *update) {
				return [[RACSignal
					defer:^{
						self.state = SQRLUpdaterStateDownloadingUpdate;

						return [self downloadAndPrepareUpdate:update];
					}]
					doCompleted:^{
						self.state = SQRLUpdaterStateAwaitingRelaunch;
					}];
			}]
			finally:^{
				if (self.state == SQRLUpdaterStateAwaitingRelaunch) return;
				self.state = SQRLUpdaterStateIdle;
			}]
			deliverOn:RACScheduler.mainThreadScheduler];
	}];

	_shipItLauncher = [[RACCommand alloc] initWithSignalBlock:^(SQRLShipItRequest *request) {
		NSURL *targetURL = request.targetBundleURL;

		NSNumber *targetWritable = nil;
		NSError *targetWritableError = nil;
		BOOL gotWritable = [targetURL getResourceValue:&targetWritable forKey:NSURLIsWritableKey error:&targetWritableError];

		// If we can't determine whether it can be written, assume
		// nonprivileged and wait for another, more canonical error.
		SQRLShipItConnection *connection = [[SQRLShipItConnection alloc] initWithRootPrivileges:(gotWritable && !targetWritable.boolValue)];

		return [connection sendRequest:request];
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

	return [[RACSignal
		defer:^{
			NSError *error = nil;
			NSDictionary *JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
			if (JSON == nil) {
				NSMutableDictionary *userInfo = [error.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
				userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Update check failed", nil);
				userInfo[NSLocalizedRecoverySuggestionErrorKey] = NSLocalizedString(@"The server sent an invalid response. Try again later.", nil);
				userInfo[SQRLUpdaterServerDataErrorKey] = data;
				if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

				return [RACSignal error:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidServerBody userInfo:userInfo]];
			}

			Class updateClass = self.updateClass;
			NSAssert([updateClass isSubclassOfClass:SQRLUpdate.class], @"%@ is not a subclass of SQRLUpdate", updateClass);

			SQRLUpdate *update = nil;
			error = nil;
			if ([JSON isKindOfClass:NSDictionary.class]) update = [MTLJSONAdapter modelOfClass:updateClass fromJSONDictionary:JSON error:&error];

			if (update == nil) {
				NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
				userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Update check failed", nil);
				userInfo[NSLocalizedRecoverySuggestionErrorKey] = NSLocalizedString(@"The server sent an invalid JSON response. Try again later.", nil);
				userInfo[SQRLUpdaterJSONObjectErrorKey] = JSON;
				if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

				return [RACSignal error:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidJSON userInfo:userInfo]];
			}

			return [RACSignal return:update];
		}]
		setNameWithFormat:@"%@ -updateFromJSONData:", self];
}

- (RACSignal *)downloadAndPrepareUpdate:(SQRLUpdate *)update {
	NSParameterAssert(update != nil);

	return [[[self
		uniqueTemporaryDirectoryForUpdate]
		flattenMap:^(NSURL *downloadDirectory) {
			return [[[self
				downloadBundleForUpdate:update intoDirectory:downloadDirectory]
				flattenMap:^(NSBundle *updateBundle) {
					return [self verifyAndPrepareUpdate:update fromBundle:updateBundle];
				}]
				doError:^(id _) {
					NSError *error = nil;
					if (![NSFileManager.defaultManager removeItemAtURL:downloadDirectory error:&error]) {
						NSLog(@"Error removing temporary download directory at %@: %@", downloadDirectory, error.sqrl_verboseDescription);
					}
				}];
		}]
		setNameWithFormat:@"%@ -downloadAndPrepareUpdate: %@", self, update];
}

- (RACSignal *)downloadBundleForUpdate:(SQRLUpdate *)update intoDirectory:(NSURL *)downloadDirectory {
	NSParameterAssert(update != nil);
	NSParameterAssert(downloadDirectory != nil);

	return [[[[[RACSignal
		defer:^{
			NSURL *zipDownloadURL = update.updateURL;
			NSMutableURLRequest *zipDownloadRequest = [NSMutableURLRequest requestWithURL:zipDownloadURL];
			[zipDownloadRequest setValue:@"application/zip" forHTTPHeaderField:@"Accept"];

			return [[[[NSURLConnection
				rac_sendAsynchronousRequest:zipDownloadRequest]
				reduceEach:^(NSURLResponse *response, NSData *bodyData) {
					if ([response isKindOfClass:NSHTTPURLResponse.class]) {
						NSHTTPURLResponse *httpResponse = (id)response;
						if (!(httpResponse.statusCode >= 200 && httpResponse.statusCode <= 299)) {
							NSDictionary *errorInfo = @{
								NSLocalizedDescriptionKey: NSLocalizedString(@"Update download failed", nil),
								NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"The server sent an invalid response. Try again later.", nil),
								SQRLUpdaterServerDataErrorKey: bodyData,
							};
							NSError *error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidServerResponse userInfo:errorInfo];
							return [RACSignal error:error];
						}
					}

					return [RACSignal return:bodyData];
				}]
				flatten]
				flattenMap:^(NSData *data) {
					NSURL *zipOutputURL = [downloadDirectory URLByAppendingPathComponent:zipDownloadURL.lastPathComponent];

					NSError *error = nil; 
					if ([data writeToURL:zipOutputURL options:NSDataWritingAtomic error:&error]) {
						return [RACSignal return:zipOutputURL];
					} else {
						return [RACSignal error:error];
					}
				}];
		}]
		doNext:^(NSURL *zipOutputURL) {
			NSLog(@"Download completed to: %@", zipOutputURL);
		}]
		flattenMap:^(NSURL *zipOutputURL) {
			return [[SQRLZipArchiver
				unzipArchiveAtURL:zipOutputURL intoDirectoryAtURL:downloadDirectory]
				doCompleted:^{
					NSError *error = nil;
					if (![NSFileManager.defaultManager removeItemAtURL:zipOutputURL error:&error]) {
						NSLog(@"Error removing downloaded archive at %@: %@", zipOutputURL, error.sqrl_verboseDescription);
					}
				}];
		}]
		then:^{
			return [self updateBundleMatchingCurrentApplicationInDirectory:downloadDirectory];
		}]
		setNameWithFormat:@"%@ -downloadBundleForUpdate: %@ intoDirectory: %@", self, update, downloadDirectory];
}

#pragma mark File Management

- (RACSignal *)uniqueTemporaryDirectoryForUpdate {
	return [[[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItConnection.shipItJobLabel];
			return [directoryManager applicationSupportURL];
		}]
		flattenMap:^(NSURL *appSupportURL) {
			NSURL *updateDirectoryTemplate = [appSupportURL URLByAppendingPathComponent:[SQRLUpdaterUniqueTemporaryDirectoryPrefix stringByAppendingString:@"XXXXXXX"]];
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
		setNameWithFormat:@"%@ -uniqueTemporaryDirectoryForUpdate", self];
}

- (RACSignal *)updateBundleMatchingCurrentApplicationInDirectory:(NSURL *)directory {
	NSParameterAssert(directory != nil);

	return [[[RACSignal
		defer:^{
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

				return [bundle.bundleIdentifier isEqual:NSRunningApplication.currentApplication.bundleIdentifier];
			}];

			if (updateBundleURL != nil) {
				return [RACSignal return:updateBundleURL];
			} else {
				NSDictionary *userInfo = @{
					NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not locate update bundle for %@ within %@", nil), NSRunningApplication.currentApplication.bundleIdentifier, directory],
				};

				return [RACSignal error:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorMissingUpdateBundle userInfo:userInfo]];
			}
		}]
		map:^(NSURL *URL) {
			return [NSBundle bundleWithURL:URL];
		}]
		setNameWithFormat:@"%@ -applicationBundleMatchingCurrentApplicationInDirectory: %@", self, directory];
}

- (RACSignal *)shipItStateURL {
	SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItConnection.shipItJobLabel];
	return directoryManager.shipItStateURL;
}

#pragma mark Installing Updates

- (RACSignal *)verifyAndPrepareUpdate:(SQRLUpdate *)update fromBundle:(NSBundle *)updateBundle {
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
		setNameWithFormat:@"%@ -verifyAndPrepareUpdate: %@ fromBundle: %@", self, update, updateBundle];
}

- (RACSignal *)prepareUpdateForInstallation:(SQRLDownloadedUpdate *)update {
	NSParameterAssert(update != nil);

	return [[[[RACSignal
		defer:^{
			NSRunningApplication *currentApplication = NSRunningApplication.currentApplication;
			SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:update.bundle.bundleURL targetBundleURL:currentApplication.bundleURL bundleIdentifier:currentApplication.bundleIdentifier launchAfterInstallation:NO];

			return [[self.shipItStateURL
				flattenMap:^(NSURL *location) {
					return [request writeToURL:location];
				}]
				concat:[RACSignal return:request]];
		}]
		flattenMap:^(SQRLShipItRequest *request) {
			return [self.shipItLauncher execute:request];
		}]
		sqrl_addTransactionWithName:NSLocalizedString(@"Preparing update", nil) description:NSLocalizedString(@"An update for %@ is being prepared. Interrupting the process could corrupt the application.", nil), NSRunningApplication.currentApplication.bundleIdentifier]
		setNameWithFormat:@"%@ -prepareUpdateForInstallation: %@", self, update];
}

- (RACSignal *)relaunchToInstallUpdate {
	return [[[[[[self.shipItStateURL
		flattenMap:^(NSURL *location) {
			return [[[[SQRLShipItRequest
				readFromURL:location]
				map:^(SQRLShipItRequest *request) {
					return [[SQRLShipItRequest alloc] initWithUpdateBundleURL:request.updateBundleURL targetBundleURL:request.targetBundleURL bundleIdentifier:request.bundleIdentifier launchAfterInstallation:YES];
				}]
				flattenMap:^(SQRLShipItRequest *request) {
					return [request writeToURL:location];
				}]
				sqrl_addTransactionWithName:NSLocalizedString(@"Preparing to relaunch", nil) description:NSLocalizedString(@"%@ is preparing to relaunch to install an update. Interrupting the process could corrupt the application.", nil), NSRunningApplication.currentApplication.bundleIdentifier];
		}]
		deliverOn:RACScheduler.mainThreadScheduler]
		doCompleted:^{
			[NSApp terminate:self];
		}]
		// Never allow `completed` to escape this signal chain (in case
		// -terminate: is asynchronous or something crazy).
		concat:[RACSignal never]]
		replay]
		setNameWithFormat:@"%@ -relaunchToInstallUpdate", self];
}

@end
