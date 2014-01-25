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
#import "SQRLUpdate.h"
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
const NSInteger SQRLUpdaterErrorInvalidServerBody = 7;

// The prefix used when creating temporary directories for updates. This will be
// followed by a random string of characters.
static NSString * const SQRLUpdaterUniqueTemporaryDirectoryPrefix = @"update.";

@interface SQRLUpdater ()

// The code signature for the running application, used to check updates before
// sending them to ShipIt.
@property (nonatomic, strong, readonly) SQRLCodeSignature *signature;

// Lazily launches ShipIt upon first subscription.
//
// Sends completed or error.
@property (nonatomic, strong, readonly) RACSignal *shipItLauncher;

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

// Verifies that an existing state is innocuous, and therefore safe to
// overwrite.
//
// This won't be the case if, for example, an update is currently being
// installed.
//
// Returns a signal which sends `existingState` then completes upon successful
// validation, or errors otherwise.
- (RACSignal *)validateExistingState:(SQRLShipItState *)existingState;

@end

@implementation SQRLUpdater {
	RACSubject *_updates;
}

#pragma mark Properties

- (RACSignal *)updates {
	return [_updates
		deliverOn:RACScheduler.mainThreadScheduler];
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

	@weakify(self);

	_prunedUpdateDirectories = [[[[[[[[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];
			return [directoryManager applicationSupportURL];
		}]
		flattenMap:^(NSURL *appSupportURL) {
			NSFileManager *manager = [[NSFileManager alloc] init];
			NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:appSupportURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsSubdirectoryDescendants errorHandler:^(NSURL *URL, NSError *error) {
				NSLog(@"Error enumerating item %@ within directory %@: %@", URL, appSupportURL, error);
				return YES;
			}];

			return [[enumerator.allObjects.rac_signal
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
		collect]
		// These operators ensure that the actual work only executes once,
		// without starting it immediately.
		concat:[RACSignal never]]
		shareWhileActive]
		take:1]
		flattenMap:^(NSArray *URLs) {
			return URLs.rac_signal;
		}]
		setNameWithFormat:@"%@ -prunedUpdateDirectories", self];

	_checkForUpdatesAction = [[[RACSignal
		defer:^{
			@strongify(self);
			return [RACSignal return:self.updateRequest];
		}]
		flattenMap:^(NSURLRequest *request) {
			return [self checkForUpdates:request];
		}]
		action];

	_updates = [[RACSubject
		subject]
		setNameWithFormat:@"%@ updates", self];

	_shipItLauncher = [[[[[[[RACSignal
		defer:^{
			NSURL *targetURL = NSRunningApplication.currentApplication.bundleURL;

			NSNumber *targetWritable = nil;
			NSError *targetWritableError = nil;
			BOOL gotWritable = [targetURL getResourceValue:&targetWritable forKey:NSURLIsWritableKey error:&targetWritableError];

			// If we can't determine whether it can be written, assume nonprivileged and
			// wait for another, more canonical error.
			return [SQRLShipItLauncher launchPrivileged:(gotWritable && !targetWritable.boolValue)];
		}]
		// These operators ensure that the actual work only executes once,
		// without starting it immediately. Super hacky.
		concat:[RACSignal return:RACUnit.defaultUnit]]
		concat:[RACSignal never]]
		shareWhileActive]
		take:1]
		ignoreValues]
		setNameWithFormat:@"shipItLauncher"];
	
	return self;
}

- (void)dealloc {
	[_updates sendCompleted];
}

#pragma mark Checking for Updates

- (RACDisposable *)startAutomaticChecksWithInterval:(NSTimeInterval)interval {
	@weakify(self);

	return [[[[RACSignal
		interval:interval onScheduler:[RACScheduler schedulerWithPriority:RACSchedulerPriorityBackground]]
		flattenMap:^(id _) {
			@strongify(self);

			return [[[self.checkForUpdatesAction
				signalWithValue:nil]
				ignoreValues]
				catch:^(NSError *error) {
					NSLog(@"Error checking for updates: %@", error);
					return [RACSignal empty];
				}];
		}]
		takeUntil:self.rac_willDeallocSignal]
		subscribeCompleted:^{}];
}

- (RACSignal *)checkForUpdates:(NSURLRequest *)request {
	NSParameterAssert(request != nil);

	BOOL updatesDisabled = (getenv("DISABLE_UPDATE_CHECK") != NULL);
	if (updatesDisabled) return [RACSignal empty];

	NSMutableURLRequest *newRequest = [request mutableCopy];
	[newRequest setValue:@"application/json" forHTTPHeaderField:@"Accept"];

	return [[[[[[[[self.prunedUpdateDirectories
		catch:^(NSError *error) {
			NSLog(@"Error pruning old updates: %@", error);
			return [RACSignal empty];
		}]
		ignoreValues]
		concat:[NSURLConnection rac_sendAsynchronousRequest:newRequest]]
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
			return [self downloadAndPrepareUpdate:update];
		}]
		doNext:^(SQRLDownloadedUpdate *update) {
			[self->_updates sendNext:update];
		}];
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
		concat:[self updateBundleMatchingCurrentApplicationInDirectory:downloadDirectory]]
		setNameWithFormat:@"%@ -downloadBundleForUpdate: %@ intoDirectory: %@", self, update, downloadDirectory];
}

#pragma mark File Management

- (RACSignal *)uniqueTemporaryDirectoryForUpdate {
	return [[[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];
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

			NSURL *updateBundleURL = [[enumerator.allObjects.rac_signal
				filter:^(NSURL *URL) {
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
				}]
				first];

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
	return [[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];
			return directoryManager.shipItStateURL;
		}]
		setNameWithFormat:@"%@ -shipItStateURL", self];
}

#pragma mark Installing Updates

- (RACSignal *)verifyAndPrepareUpdate:(SQRLUpdate *)update fromBundle:(NSBundle *)updateBundle {
	NSParameterAssert(update != nil);
	NSParameterAssert(updateBundle != nil);

	return [[[[self.signature
		verifyBundleAtURL:updateBundle.bundleURL]
		concat:[RACSignal return:[[SQRLDownloadedUpdate alloc] initWithUpdate:update bundle:updateBundle]]]
		flattenMap:^(SQRLDownloadedUpdate *downloadedUpdate) {
			return [[self
				prepareUpdateForInstallation:downloadedUpdate]
				concat:[RACSignal return:downloadedUpdate]];
		}]
		setNameWithFormat:@"%@ -verifyAndPrepareUpdate: %@ fromBundle: %@", self, update, updateBundle];
}

- (RACSignal *)validateExistingState:(SQRLShipItState *)existingState {
	return [[RACSignal
		defer:^{
			if (existingState.installerState != SQRLInstallerStateNothingToDo) {
				// If this happens, shit is crazy, because it implies that an
				// update is being installed over us right now.
				NSDictionary *userInfo = @{
					NSLocalizedDescriptionKey: NSLocalizedString(@"Installation in progress", nil),
					NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"An update for %@ is already in progress.", nil), NSRunningApplication.currentApplication.bundleIdentifier],
				};

				return [RACSignal error:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorPreparingUpdateJob userInfo:userInfo]];
			}

			return [RACSignal return:existingState];
		}]
		setNameWithFormat:@"%@ -validateExistingState: %@", self, existingState];
}

- (RACSignal *)prepareUpdateForInstallation:(SQRLDownloadedUpdate *)update {
	NSParameterAssert(update != nil);

	return [[[[[[[[SQRLShipItState
		readUsingURL:self.shipItStateURL]
		catchTo:[RACSignal empty]]
		flattenMap:^(SQRLShipItState *existingState) {
			return [self validateExistingState:existingState];
		}]
		ignoreValues]
		concat:[RACSignal defer:^{
			SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:NSRunningApplication.currentApplication.bundleURL updateBundleURL:update.bundle.bundleURL bundleIdentifier:NSRunningApplication.currentApplication.bundleIdentifier codeSignature:self.signature];
			return [state writeUsingURL:self.shipItStateURL];
		}]]
		concat:self.shipItLauncher]
		sqrl_addTransactionWithName:NSLocalizedString(@"Preparing update", nil) description:NSLocalizedString(@"An update for %@ is being prepared. Interrupting the process could corrupt the application.", nil), NSRunningApplication.currentApplication.bundleIdentifier]
		setNameWithFormat:@"%@ -prepareUpdateForInstallation: %@", self, update];
}

- (RACSignal *)relaunchToInstallUpdate {
	return [[[[[[[SQRLShipItState
		readUsingURL:self.shipItStateURL]
		flattenMap:^(SQRLShipItState *existingState) {
			return [self validateExistingState:existingState];
		}]
		flattenMap:^(SQRLShipItState *state) {
			state.relaunchAfterInstallation = YES;
			return [[state
				writeUsingURL:self.shipItStateURL]
				sqrl_addTransactionWithName:NSLocalizedString(@"Preparing to relaunch", nil) description:NSLocalizedString(@"%@ is preparing to relaunch to install an update. Interrupting the process could corrupt the application.", nil), NSRunningApplication.currentApplication.bundleIdentifier];
		}]
		deliverOn:RACScheduler.mainThreadScheduler]
		doCompleted:^{
			[NSApp terminate:self];
		}]
		// Never allow `completed` to escape this signal chain (in case
		// -terminate: is asynchronous or something crazy).
		concat:[RACSignal never]]
		setNameWithFormat:@"%@ -relaunchToInstallUpdate", self];
}

@end
