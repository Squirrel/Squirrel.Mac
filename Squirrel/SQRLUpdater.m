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
#import "SQRLUpdate.h"
#import "SQRLZipArchiver.h"
#import "SQRLShipItRequest.h"
#import <ReactiveObjC/EXTScope.h>
#import <ReactiveObjC/ReactiveObjC.h>
#import <sys/mount.h>

NSString * const SQRLUpdaterErrorDomain = @"SQRLUpdaterErrorDomain";
NSString * const SQRLUpdaterServerDataErrorKey = @"SQRLUpdaterServerDataErrorKey";
NSString * const SQRLUpdaterJSONObjectErrorKey = @"SQRLUpdaterJSONObjectErrorKey";

const NSInteger SQRLUpdaterErrorMissingUpdateBundle = 2;
const NSInteger SQRLUpdaterErrorPreparingUpdateJob = 3;
const NSInteger SQRLUpdaterErrorRetrievingCodeSigningRequirement = 4;
const NSInteger SQRLUpdaterErrorInvalidServerResponse = 5;
const NSInteger SQRLUpdaterErrorInvalidJSON = 6;
const NSInteger SQRLUpdaterErrorInvalidServerBody = 7;

/// The application's being run on a read-only volume.
const NSInteger SQRLUpdaterErrorReadOnlyVolume = 8;

const NSTimeInterval SQURLUpdaterZipDownloadTimeoutSeconds = 20 * 60;

// The prefix used when creating temporary directories for updates. This will be
// followed by a random string of characters.
static NSString * const SQRLUpdaterUniqueTemporaryDirectoryPrefix = @"update.";

@interface SQRLUpdater ()

@property (atomic, readwrite) SQRLUpdaterState state;

/// The etag of the currently downloaded update, nil if no update has been
/// downloaded.
@property (atomic, copy) NSString *etag;

// The code signature for the running application, used to check updates before
// sending them to ShipIt.
@property (nonatomic, strong, readonly) SQRLCodeSignature *signature;

// Lazily launches ShipIt upon first subscription.
//
// Sends completed or error.
@property (nonatomic, strong, readonly) RACSignal *shipItLauncher;

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
	return [self initWithUpdateRequest:updateRequest requestForDownload:^(NSURL *downloadURL) {
		return [NSURLRequest requestWithURL:downloadURL];
	}];
}

- (id)initWithUpdateRequest:(NSURLRequest *)updateRequest forVersion: (NSString*) version {
	return [self initWithUpdateRequest:updateRequest requestForDownload:^(NSURL *downloadURL) {
		return [NSURLRequest requestWithURL:downloadURL];
	} forVersion:version useMode:JSONFILE];
}

- (id)initWithUpdateRequest:(NSURLRequest *)updateRequest requestForDownload:(SQRLRequestForDownload)requestForDownload {
	return [self initWithUpdateRequest:updateRequest requestForDownload:^(NSURL *downloadURL) {
		return [NSURLRequest requestWithURL:downloadURL];
	} forVersion:nil useMode:RELEASESERVER];
}

- (id)initWithUpdateRequest:(NSURLRequest *)updateRequest requestForDownload:(SQRLRequestForDownload)requestForDownload
				 forVersion:(NSString*) version useMode:(SQRLUpdaterMode) mode {

	//! download simple file

	NSParameterAssert(updateRequest != nil);
	NSParameterAssert(requestForDownload != nil);

	if (mode == JSONFILE) {
		NSParameterAssert(version != nil);
	}

	self = [super init];
	if (self == nil) return nil;

	_requestForDownload = [requestForDownload copy];
	NSMutableURLRequest* mutableUpdateRequest = [updateRequest mutableCopy];

	if (mode == JSONFILE) {
		mutableUpdateRequest.cachePolicy = NSURLRequestReloadIgnoringCacheData;
	}
	_updateRequest = mutableUpdateRequest;
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

	_checkForUpdatesCommand = [[RACCommand alloc] initWithEnabled:[RACSignal return:@(!updatesDisabled)] signalBlock:^(id _) {
		@strongify(self);
		NSParameterAssert(self.updateRequest != nil);

		// TODO: Maybe allow this to be an argument to the command?
		NSMutableURLRequest *request = [self.updateRequest mutableCopy];
		[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

		return [[[[[[[[self
			performHousekeeping]

			//! get file from server
			then:^{
				self.state = SQRLUpdaterStateCheckingForUpdate;

				return [NSURLConnection rac_sendAsynchronousRequest:request];
			}]
			reduceEach:^(NSURLResponse *response, NSData *bodyData) {
				if ([response isKindOfClass:NSHTTPURLResponse.class]) {
					NSHTTPURLResponse *httpResponse = (id)response;

					BOOL readOnlyVolume = [self isRunningOnReadOnlyVolume];
					if (readOnlyVolume) {
						NSDictionary *errorInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Cannot update while running on a read-only volume", nil),
						NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"The application is on a read-only volume. Please move the application and try again. If you're on macOS Sierra or later, you'll need to move the application out of the Downloads directory. See https://github.com/Squirrel/Squirrel.Mac/issues/182 for more information.", nil),
						};
						NSError *error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorReadOnlyVolume userInfo:errorInfo];
						return [RACSignal error:error];
					}

					if (mode == RELEASESERVER) {
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
					} else if (mode == JSONFILE) {
						NSError *error = nil;
						NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&error];

						if (dict == nil) {
							NSMutableDictionary *userInfo = [error.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
							userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Update check failed", nil);
							userInfo[NSLocalizedRecoverySuggestionErrorKey] = NSLocalizedString(@"The server sent an invalid response. Try again later.", nil);
							userInfo[SQRLUpdaterServerDataErrorKey] = bodyData;
							if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

							return [RACSignal error:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidServerBody userInfo:userInfo]];
						}

						NSString *currentRelease = dict[@"currentRelease"];
						if(currentRelease) {
							//! if CDN points to the currently running version as the latest version, bail out
							if([currentRelease isEqualToString:version]) {
								NSLog(@"The running client is already the latest version.");
								return [RACSignal empty];
							}

							if ([version compare:currentRelease options:NSNumericSearch] == NSOrderedDescending) {
								// currentRelease is lower than version.
								// Might be a new version for testing that is not deployed yet
								// no roll back
								NSLog(@"The running client is newer than the latest deployed release. Not downgrading.");
								return [RACSignal empty];
							}

							//! @todo find latest
							NSArray *releases = dict[@"releases"];
							for(NSDictionary* release in releases) {
								if([currentRelease isEqualToString:release[@"version"]]) {
									bodyData = [NSJSONSerialization dataWithJSONObject:release[@"updateTo"]
																				options:0 error:&error];
									break;
								}
							}
						}
					}
				}
				if (bodyData == nil) {
					NSMutableDictionary *userInfo = [error.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
					userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Update check failed", nil);
					userInfo[NSLocalizedRecoverySuggestionErrorKey] = NSLocalizedString(@"The server sent an invalid response. Try again later.", nil);
					userInfo[SQRLUpdaterServerDataErrorKey] = bodyData;
					if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

					return [RACSignal error:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidServerBody userInfo:userInfo]];
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

	_shipItLauncher = [[[RACSignal
		defer:^{
			@strongify(self);

			NSURL *targetURL = NSRunningApplication.currentApplication.bundleURL;

			BOOL targetWritable = [self canWriteToURL:targetURL];
			BOOL parentWritable = [self canWriteToURL:targetURL.URLByDeletingLastPathComponent];
			return [SQRLShipItLauncher launchPrivileged:!targetWritable || !parentWritable];
		}]
		replayLazily]
		setNameWithFormat:@"shipItLauncher"];
	
	return self;
}

- (BOOL)canWriteToURL:(NSURL *)fileURL {
	NSNumber *writable = nil;
	NSError *writableError = nil;
	BOOL gotWritable = [fileURL getResourceValue:&writable forKey:NSURLIsWritableKey error:&writableError];
	// If we can't determine whether it can be written, assume nonprivileged and
	// wait for another, more canonical error.
	return !gotWritable || writable.boolValue;
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
			void (^cleanUp)(void) = ^{
				NSError *error;
				if (![NSFileManager.defaultManager removeItemAtURL:downloadDirectory error:&error]) {
					NSLog(@"Error removing temporary download directory at %@: %@", downloadDirectory, error.sqrl_verboseDescription);
				}
			};

			return [[[self
				downloadBundleForUpdate:update intoDirectory:downloadDirectory]
				flattenMap:^(NSBundle *updateBundle) {
					// If the bundle is nil it means our conditional GET told us
					// we already downloaded the update. So just clean up.
					if (updateBundle == nil) {
						cleanUp();
						return [RACSignal empty];
					}

					return [self verifyAndPrepareUpdate:update fromBundle:updateBundle];
				}]
				doError:^(id _) {
					cleanUp();
				}];
		}]
		setNameWithFormat:@"%@ -downloadAndPrepareUpdate: %@", self, update];
}

- (RACSignal *)unarchiveAndPrepareData:(NSData *)data withName:(NSString *)name intoDirectory:(NSURL *)downloadDirectory {
	return [[[[[RACSignal
		defer:^{
			NSURL *zipOutputURL = [downloadDirectory URLByAppendingPathComponent:name];
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
			return [[[[SQRLZipArchiver
				unzipArchiveAtURL:zipOutputURL intoDirectoryAtURL:downloadDirectory]
				ignoreValues]
				concat:[RACSignal return:zipOutputURL]]
				doCompleted:^{
					NSError *error = nil;
					if (![NSFileManager.defaultManager removeItemAtURL:zipOutputURL error:&error]) {
						NSLog(@"Error removing downloaded archive at %@: %@", zipOutputURL, error.sqrl_verboseDescription);
					}
				}];
		}]
		flattenMap:^(NSURL *zipOutputURL) {
			return [self updateBundleMatchingCurrentApplicationInDirectory:downloadDirectory];
		}]
		setNameWithFormat:@"%@ -unarchiveAndPrepareData:withName: %@ intoDirectory: %@", self, name, downloadDirectory];
}

- (RACSignal *)downloadBundleForUpdate:(SQRLUpdate *)update intoDirectory:(NSURL *)downloadDirectory {
	NSParameterAssert(update != nil);
	NSParameterAssert(downloadDirectory != nil);

	return [[RACSignal
		defer:^{
			NSURL *zipDownloadURL = update.updateURL;
			NSMutableURLRequest *zipDownloadRequest = [self.requestForDownload(zipDownloadURL) mutableCopy];

			[zipDownloadRequest setValue:@"application/zip" forHTTPHeaderField:@"Accept"];
			if (self.etag != nil) {
				[zipDownloadRequest setValue:self.etag forHTTPHeaderField:@"If-None-Match"];
			}

			[zipDownloadRequest setTimeoutInterval:SQURLUpdaterZipDownloadTimeoutSeconds];

			return [[[NSURLConnection
				rac_sendAsynchronousRequest:zipDownloadRequest]
				reduceEach:^(NSURLResponse *response, NSData *bodyData) {
					if ([response isKindOfClass:NSHTTPURLResponse.class]) {
						NSHTTPURLResponse *httpResponse = (id)response;

						if (httpResponse.statusCode == 304 /* Not Modified */) {
							return [RACSignal return:nil];
						}

						if (!(httpResponse.statusCode >= 200 && httpResponse.statusCode <= 299)) {
							NSDictionary *errorInfo = @{
								NSLocalizedDescriptionKey: NSLocalizedString(@"Update download failed", nil),
								NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"The server sent an invalid response. Try again later.", nil),
								SQRLUpdaterServerDataErrorKey: bodyData,
							};
							NSError *error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidServerResponse userInfo:errorInfo];
							return [RACSignal error:error];
						}

						self.etag = httpResponse.allHeaderFields[@"ETag"];
					}

					return [self unarchiveAndPrepareData:bodyData withName:zipDownloadURL.lastPathComponent intoDirectory:downloadDirectory];
				}]
				flatten];
		}]
		setNameWithFormat:@"%@ -downloadBundleForUpdate: %@ intoDirectory: %@", self, update, downloadDirectory];
}

#pragma mark File Management

- (RACSignal *)uniqueTemporaryDirectoryForUpdate {
	return [[[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];
			return [directoryManager storageURL];
		}]
		flattenMap:^(NSURL *storageURL) {
			NSURL *updateDirectoryTemplate = [storageURL URLByAppendingPathComponent:[SQRLUpdaterUniqueTemporaryDirectoryPrefix stringByAppendingString:@"XXXXXXX"]];
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
	return [[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];
			return directoryManager.shipItStateURL;
		}]
		setNameWithFormat:@"%@ -shipItStateURL", self];
}

/// Is the host app running on a read-only volume?
- (BOOL)isRunningOnReadOnlyVolume {
	struct statfs statfsInfo;
	NSURL *bundleURL = NSRunningApplication.currentApplication.bundleURL;
	int result = statfs(bundleURL.fileSystemRepresentation, &statfsInfo);
	if (result == 0) {
		return (statfsInfo.f_flags & MNT_RDONLY) != 0;
	} else {
		// If we can't even check if the volume is read-only, assume it is.
		return true;
	}
}

- (RACSignal *)performHousekeeping {
	return [[RACSignal
		merge:@[ [self pruneUpdateDirectories], [self truncateLogs] ]]
		catch:^(NSError *error) {
			NSLog(@"Error doing housekeeping: %@", error);
			return [RACSignal empty];
		}];
}

/// Lazily removes outdated temporary directories (used for previous updates)
/// upon subscription.
///
/// Pruning directories while an update is pending or in progress will result in
/// undefined behavior.
///
/// Sends each removed directory then completes, or errors, on an unspecified
/// thread.
- (RACSignal *)pruneUpdateDirectories {
	return [[[RACSignal
		defer:^{
			// If we already have updates downloaded we don't wanna prune them.
			if (self.state == SQRLUpdaterStateAwaitingRelaunch) return [RACSignal empty];

			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];
			return [directoryManager storageURL];
		}]
		flattenMap:^(NSURL *storageURL) {
			NSFileManager *manager = [[NSFileManager alloc] init];
			NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:storageURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsSubdirectoryDescendants errorHandler:^(NSURL *URL, NSError *error) {
				NSLog(@"Error enumerating item %@ within directory %@: %@", URL, storageURL, error);
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
		setNameWithFormat:@"%@ -prunedUpdateDirectories", self];
}


// Like truncation, but backwards.
- (RACSignal *)backwardTruncateFile:(NSURL *)fileURL {
	return [RACSignal defer:^{
		static const NSInteger MAX_LENGTH = 1024 * 1024 * 8;

		NSError *error;
		NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:fileURL error:&error];
		if (handle == nil) return [RACSignal error:error];

		unsigned long long fileLength = [handle seekToEndOfFile];
		if (fileLength <= MAX_LENGTH) return [RACSignal empty];

		[handle seekToFileOffset:fileLength - MAX_LENGTH];
		NSData *mostRecentData = [handle readDataToEndOfFile];
		[handle truncateFileAtOffset:0];
		[handle writeData:mostRecentData];

		return [RACSignal empty];
	}];
}

- (RACSignal *)truncateLogs {
	return [[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];
			return [RACSignal zip:@[ [directoryManager shipItStdoutURL], [directoryManager shipItStderrURL] ]];
		}]
		reduceEach:^(NSURL *stdoutURL, NSURL *stderrURL) {
			return [RACSignal merge:@[ [self backwardTruncateFile:stdoutURL], [self backwardTruncateFile:stderrURL] ]];
		}];
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
			NSBundle *appBundle = [NSBundle bundleWithURL:currentApplication.bundleURL];
			// Only use the update bundle's name if the user hasn't renamed the
			// app themselves.
			BOOL useUpdateBundleName = [appBundle.sqrl_executableName isEqual:currentApplication.bundleURL.lastPathComponent.stringByDeletingPathExtension];

			SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:update.bundle.bundleURL targetBundleURL:currentApplication.bundleURL bundleIdentifier:currentApplication.bundleIdentifier launchAfterInstallation:NO useUpdateBundleName:useUpdateBundleName];
			return [request writeUsingURL:self.shipItStateURL];
		}]
		then:^{
			return self.shipItLauncher;
		}]
		sqrl_addTransactionWithName:NSLocalizedString(@"Preparing update", nil) description:NSLocalizedString(@"An update for %@ is being prepared. Interrupting the process could corrupt the application.", nil), NSRunningApplication.currentApplication.bundleIdentifier]
		setNameWithFormat:@"%@ -prepareUpdateForInstallation: %@", self, update];
}

- (RACSignal *)relaunchToInstallUpdate {
	return [[[[[[[[SQRLShipItRequest
		readUsingURL:self.shipItStateURL]
		map:^(SQRLShipItRequest *request) {
			return [[SQRLShipItRequest alloc] initWithUpdateBundleURL:request.updateBundleURL targetBundleURL:request.targetBundleURL bundleIdentifier:request.bundleIdentifier launchAfterInstallation:YES useUpdateBundleName:request.useUpdateBundleName];
		}]
		flattenMap:^(SQRLShipItRequest *request) {
			return [[request
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
		replay]
		setNameWithFormat:@"%@ -relaunchToInstallUpdate", self];
}

@end
