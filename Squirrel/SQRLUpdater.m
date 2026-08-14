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
#import "SQRLDownloader.h"
#import "SQRLShipItLauncher.h"
#import "SQRLUpdate.h"
#import "SQRLUpdateDelta.h"
#import "SUBinaryDeltaApply.h"
#import "SQRLZipArchiver.h"
#import "SQRLShipItRequest.h"
#import <ReactiveObjC/EXTScope.h>
#import <ReactiveObjC/ReactiveObjC.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

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

const NSInteger SQRLUpdaterErrorInvalidUpdatePackage = 9;

const NSTimeInterval SQURLUpdaterZipDownloadTimeoutSeconds = 20 * 60;

// The prefix used when creating temporary directories for updates. This will be
// followed by a random string of characters.
static NSString * const SQRLUpdaterUniqueTemporaryDirectoryPrefix = @"update.";

// Kept in the storage directory, beside the per-attempt update directories, so
// an interrupted package download can continue on a later check or launch.
static NSString * const SQRLUpdaterResumeDataFileName = @"download.resumedata";
// The delta and the ZIP are different URLs; sharing one file would have each
// downloader discard the other's resume data.
static NSString * const SQRLUpdaterDeltaResumeDataFileName = @"delta.resumedata";

// How much of an error response body to attach to the error.
static const NSUInteger SQRLUpdaterServerDataErrorLimit = 64 * 1024;

// How long -[NSApplication terminate:] may wait for an in-flight download to
// hand over its resume data.
static const NSTimeInterval SQRLUpdaterTerminationResumeDataTimeout = 2;

BOOL isVersionStandard(NSString* version) {
	NSCharacterSet *alphaNums = [NSCharacterSet decimalDigitCharacterSet];

	NSArray* versionParts = [version componentsSeparatedByString:@"."];
	BOOL versionBad = [versionParts count] != 3;
	for (NSString* part in versionParts) {
		versionBad = versionBad || part.length == 0 || ![alphaNums isSupersetOfSet:[NSCharacterSet characterSetWithCharactersInString:part]];
	}

	return !versionBad;
}

@interface SQRLUpdater ()

@property (atomic, readwrite) SQRLUpdaterState state;

/// The etag of the currently downloaded update, nil if no update has been
/// downloaded.
@property (atomic, copy) NSString *etag;

// Digest of the delta the staged update was made from. Plays the ETag's role
// for the delta path: a later check offering the same delta has nothing to do.
@property (atomic, copy) NSString *appliedDeltaDigest;

// Digest of a delta that downloaded intact but would not apply or verify.
// That does not change within a process, so later checks go straight to the
// ZIP instead of fetching and applying it again.
@property (atomic, copy) NSString *unusableDeltaDigest;

// The code signature for the running application, used to check updates before
// sending them to ShipIt.
@property (nonatomic, strong, readonly) SQRLCodeSignature *signature;

// Lazily launches ShipIt upon first subscription.
//
// Sends completed or error.
@property (nonatomic, strong, readonly) RACSignal *shipItLauncher;

+ (bool) isVersionAllowedForUpdate:(NSString*)targetVersion from:(NSString*)currentVersion;

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

// Checks a downloaded file against a declared size and SHA-256 digest, deleting
// it on mismatch.
//
// Returns a signal which completes, or errors with
// `SQRLUpdaterErrorInvalidUpdatePackage`, on a background thread. Completes
// immediately when neither is declared.
- (RACSignal *)verifyFileAtURL:(NSURL *)fileURL size:(NSNumber *)size digest:(NSString *)digest;

// Produces the verified update in `downloadDirectory`: from `update.delta`
// applied to the running application when that delta targets the running
// version, and otherwise, or if anything about the delta fails, from the
// full archive at `update.updateURL`.
//
// Returns a signal which sends a `SQRLDownloadedUpdate` (or nil when a
// conditional GET says the archive was already downloaded) then completes, or
// errors, on a background thread.
- (RACSignal *)downloadedUpdateForUpdate:(SQRLUpdate *)update intoDirectory:(NSURL *)downloadDirectory;

// Downloads `delta`, verifies it, and applies it to a copy of the running
// application inside `downloadDirectory`.
//
// Returns a signal which sends the patched `NSBundle` then completes, or
// errors, on a background thread.
- (RACSignal *)bundleByApplyingDelta:(SQRLUpdateDelta *)delta intoDirectory:(NSURL *)downloadDirectory;

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

// Validates the code signature (and, with ElectronSquirrelPreventDowngrades,
// the version) of the given update bundle.
//
// update - Describes the update to verify. This must not be nil.
//
// Returns a signal which sends a `SQRLDownloadedUpdate` then completes, or
// errors, on a background thread.
- (RACSignal *)verifyUpdate:(SQRLUpdate *)update fromBundle:(NSBundle *)updateBundle;

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

@implementation SQRLUpdater {
	RACSubject *_downloadProgress;
}

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
	return [self initWithUpdateRequest:updateRequest requestForDownload:requestForDownload forVersion:nil useMode:RELEASESERVER];
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
	_downloadProgress = [[RACSubject subject] setNameWithFormat:@"%@ downloadProgress", self];

	[[[NSNotificationCenter.defaultCenter
		rac_addObserverForName:NSApplicationWillTerminateNotification object:nil]
		takeUntil:self.rac_willDeallocSignal]
		subscribeNext:^(id _) {
			[SQRLDownloader cancelAllWritingResumeDataWithTimeout:SQRLUpdaterTerminationResumeDataTimeout];
		}];
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
				BOOL readOnlyVolume = [self isRunningOnReadOnlyVolume];
				if (readOnlyVolume) {
					NSDictionary *errorInfo = @{
					NSLocalizedDescriptionKey: NSLocalizedString(@"Cannot update while running on a read-only volume", nil),
					NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"The application is on a read-only volume. Please move the application and try again. If you're on macOS Sierra or later, you'll need to move the application out of the Downloads directory. See https://github.com/Squirrel/Squirrel.Mac/issues/182 for more information.", nil),
					};
					NSError *error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorReadOnlyVolume userInfo:errorInfo];
					return [RACSignal error:error];
				}

				if ([response isKindOfClass:NSHTTPURLResponse.class] && mode == RELEASESERVER) {
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

				if (mode == JSONFILE) {
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

	__block BOOL shipItSubmitted = NO;
	_shipItLauncher = [[RACSignal
		defer:^{
			@strongify(self);

			// replayLazily would cache a terminal error (e.g. the user
			// cancelling the auth prompt, or a transient SMJobSubmit failure)
			// and replay it to every future check. Memoize success only so
			// errors retry on the next subscription.
			if (shipItSubmitted) return [RACSignal empty];

			NSURL *targetURL = NSRunningApplication.currentApplication.bundleURL.URLByResolvingSymlinksInPath;

			BOOL targetWritable = [self canWriteToURL:targetURL];
			BOOL parentWritable = [self canWriteToURL:targetURL.URLByDeletingLastPathComponent];
			BOOL launchPrivileged = !targetWritable || !parentWritable;
			if ([[NSUserDefaults standardUserDefaults] boolForKey:@"SquirrelMacEnableDirectContentsWrite"]) {
				// If SquirrelMacEnableDirectContentsWrite is enabled we don't care if the parent directory is writeable or not
				launchPrivileged = !targetWritable;
			}
			return [[SQRLShipItLauncher launchPrivileged:launchPrivileged]
				doCompleted:^{
					shipItSubmitted = YES;
				}];
		}]
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

+ (bool) isVersionAllowedForUpdate:(NSString*)targetVersion from:(NSString*)currentVersion {
	return [currentVersion compare:targetVersion options:NSNumericSearch] != NSOrderedDescending;
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
				if ([downloadDirectory checkResourceIsReachableAndReturnError:NULL] && ![NSFileManager.defaultManager removeItemAtURL:downloadDirectory error:&error]) {
					NSLog(@"Error removing temporary download directory at %@: %@", downloadDirectory, error.sqrl_verboseDescription);
				}
			};

			return [[[self
				downloadedUpdateForUpdate:update intoDirectory:downloadDirectory]
				flattenMap:^(SQRLDownloadedUpdate *downloadedUpdate) {
					// Nil means our conditional GET told us we already
					// downloaded the update. So just clean up.
					if (downloadedUpdate == nil) {
						cleanUp();
						return [RACSignal empty];
					}

					return [[self prepareUpdateForInstallation:downloadedUpdate] then:^{
						return [RACSignal return:downloadedUpdate];
					}];
				}]
				doError:^(id _) {
					// The archive behind that ETag never became a prepared
					// update, so a 304 for it must not read as "already have it".
					self.etag = nil;
					self.appliedDeltaDigest = nil;
					cleanUp();
				}];
		}]
		setNameWithFormat:@"%@ -downloadAndPrepareUpdate: %@", self, update];
}

- (RACSignal *)downloadedUpdateForUpdate:(SQRLUpdate *)update intoDirectory:(NSURL *)downloadDirectory {
	RACSignal * (^fullUpdateIntoDirectory)(NSURL *) = ^(NSURL *directory) {
		return [[self
			downloadBundleForUpdate:update intoDirectory:directory]
			flattenMap:^(NSBundle *updateBundle) {
				if (updateBundle == nil) return [RACSignal return:nil];
				return [self verifyUpdate:update fromBundle:updateBundle];
			}];
	};

	SQRLUpdateDelta *delta = update.delta;
	if (delta == nil) return fullUpdateIntoDirectory(downloadDirectory);

	NSURL *runningURL = NSRunningApplication.currentApplication.bundleURL;
	NSString *runningVersion = (runningURL == nil ? nil : [NSBundle bundleWithURL:runningURL].sqrl_bundleVersion);
	if (![delta.fromVersion isEqual:runningVersion]) {
		NSLog(@"Delta update is from %@ but %@ is running, downloading the full update instead", delta.fromVersion, runningVersion);
		return fullUpdateIntoDirectory(downloadDirectory);
	}

	// Already applied and staged from this delta: nothing to download, the
	// same answer a 304 gives the ZIP path.
	if ([delta.digest isEqual:self.appliedDeltaDigest]) return [RACSignal return:nil];
	if ([delta.digest isEqual:self.unusableDeltaDigest]) return fullUpdateIntoDirectory(downloadDirectory);

	return [[[[self
		bundleByApplyingDelta:delta intoDirectory:downloadDirectory]
		flattenMap:^(NSBundle *updateBundle) {
			// The apply copies file flags (a Finder-locked file's uchg) over
			// from the running app; ShipIt cannot strip xattrs from or replace
			// an immutable file, so the staged copy carries none.
			[self clearFileFlagsUnderURL:updateBundle.bundleURL];
			return [[[self
				verifyUpdate:update fromBundle:updateBundle]
				doError:^(NSError *error) {
					self.unusableDeltaDigest = delta.digest;
				}]
				doCompleted:^{
					self.appliedDeltaDigest = delta.digest;
				}];
		}]
		catch:^(NSError *error) {
			NSLog(@"Delta update from %@ could not be used (%@), downloading the full update instead", delta.fromVersion, error.sqrl_verboseDescription);

			// Whatever the apply left behind may not be removable as is (it has
			// the running app's file flags), so clear those, remove it, and
			// give the ZIP a directory of its own either way.
			[self clearFileFlagsUnderURL:downloadDirectory];
			NSError *removeError = nil;
			if (![NSFileManager.defaultManager removeItemAtURL:downloadDirectory error:&removeError]) {
				NSLog(@"Could not remove %@ after a failed delta: %@", downloadDirectory.path, removeError.sqrl_verboseDescription);
			}

			return [[self uniqueTemporaryDirectoryForUpdate] flattenMap:^(NSURL *freshDirectory) {
				return [[fullUpdateIntoDirectory(freshDirectory)
					doNext:^(SQRLDownloadedUpdate *downloadedUpdate) {
						if (downloadedUpdate == nil) [NSFileManager.defaultManager removeItemAtURL:freshDirectory error:NULL];
					}]
					doError:^(NSError *error) {
						[NSFileManager.defaultManager removeItemAtURL:freshDirectory error:NULL];
					}];
			}];
		}]
		setNameWithFormat:@"%@ -downloadedUpdateForUpdate: %@ intoDirectory: %@", self, update, downloadDirectory];
}

- (void)clearFileFlagsUnderURL:(NSURL *)directoryURL {
	for (NSURL *itemURL in [NSFileManager.defaultManager enumeratorAtURL:directoryURL includingPropertiesForKeys:nil options:0 errorHandler:nil]) {
		lchflags(itemURL.fileSystemRepresentation, 0);
	}
}

- (RACSignal *)bundleByApplyingDelta:(SQRLUpdateDelta *)delta intoDirectory:(NSURL *)downloadDirectory {
	NSParameterAssert(delta != nil);
	NSParameterAssert(downloadDirectory != nil);

	return [[RACSignal
		defer:^{
			NSMutableURLRequest *request = [self.requestForDownload(delta.deltaURL) mutableCopy];
			[request setValue:@"application/octet-stream" forHTTPHeaderField:@"Accept"];
			[request setTimeoutInterval:SQURLUpdaterZipDownloadTimeoutSeconds];

			// A fixed name: the URL is the server's, the directory is ours.
			NSURL *deltaOutputURL = [downloadDirectory URLByAppendingPathComponent:@"update.delta"];
			NSURL *resumeDataURL = [downloadDirectory.URLByDeletingLastPathComponent URLByAppendingPathComponent:SQRLUpdaterDeltaResumeDataFileName];
			SQRLDownloader *downloader = [[SQRLDownloader alloc] initWithRequest:request resumeDataURL:resumeDataURL];
			[downloader.progress subscribeNext:^(SQRLDownloadProgress *progress) {
				[self->_downloadProgress sendNext:progress];
			}];

			return [[[downloader
				downloadToURL:deltaOutputURL]
				reduceEach:^(NSURLResponse *response, NSURL *deltaFileURL) {
					if ([response isKindOfClass:NSHTTPURLResponse.class]) {
						NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
						if (statusCode < 200 || statusCode > 299) {
							[NSFileManager.defaultManager removeItemAtURL:deltaFileURL error:NULL];
							return [RACSignal error:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidServerResponse userInfo:@{
								NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Delta download answered %ld", nil), (long)statusCode],
								NSURLErrorKey: delta.deltaURL,
							}]];
						}
					}

					NSURL *sourceURL = NSRunningApplication.currentApplication.bundleURL.URLByResolvingSymlinksInPath;
					NSURL *patchedURL = [downloadDirectory URLByAppendingPathComponent:sourceURL.lastPathComponent];
					return [[[self
						verifyFileAtURL:deltaFileURL size:delta.size digest:delta.digest]
						then:^{
							return [RACSignal startLazilyWithScheduler:[RACScheduler schedulerWithPriority:RACSchedulerPriorityBackground] block:^(id<RACSubscriber> subscriber) {
								NSLog(@"Applying delta %@ to %@", deltaFileURL.lastPathComponent, sourceURL.path);
								NSError *error = nil;
								BOOL applied = applyBinaryDelta(sourceURL.path, patchedURL.path, deltaFileURL.path, NO, ^(double progress){}, &error);
								[NSFileManager.defaultManager removeItemAtURL:deltaFileURL error:NULL];

								if (applied) {
									[subscriber sendCompleted];
								} else {
									self.unusableDeltaDigest = delta.digest;
									[subscriber sendError:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidUpdatePackage userInfo:@{
										NSLocalizedDescriptionKey: NSLocalizedString(@"Could not apply the delta update", nil),
										NSURLErrorKey: delta.deltaURL,
										NSUnderlyingErrorKey: error ?: [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidUpdatePackage userInfo:nil],
									}]];
								}
							}];
						}]
						then:^{
							return [self updateBundleMatchingCurrentApplicationInDirectory:downloadDirectory];
						}];
				}]
				flatten];
		}]
		setNameWithFormat:@"%@ -bundleByApplyingDelta: %@ intoDirectory: %@", self, delta, downloadDirectory];
}

- (RACSignal *)unarchiveAndPrepareZipAtURL:(NSURL *)zipURL intoDirectory:(NSURL *)downloadDirectory {
	return [[[[[SQRLZipArchiver
		unzipArchiveAtURL:zipURL intoDirectoryAtURL:downloadDirectory]
		ignoreValues]
		doCompleted:^{
			NSError *error = nil;
			if (![NSFileManager.defaultManager removeItemAtURL:zipURL error:&error]) {
				NSLog(@"Error removing downloaded archive at %@: %@", zipURL, error.sqrl_verboseDescription);
			}
		}]
		then:^{
			return [self updateBundleMatchingCurrentApplicationInDirectory:downloadDirectory];
		}]
		setNameWithFormat:@"%@ -unarchiveAndPrepareZipAtURL: %@ intoDirectory: %@", self, zipURL, downloadDirectory];
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

			// A fixed name: the URL is the server's, the directory is ours.
			NSURL *zipOutputURL = [downloadDirectory URLByAppendingPathComponent:@"update.zip"];
			NSURL *resumeDataURL = [downloadDirectory.URLByDeletingLastPathComponent URLByAppendingPathComponent:SQRLUpdaterResumeDataFileName];
			SQRLDownloader *downloader = [[SQRLDownloader alloc] initWithRequest:zipDownloadRequest resumeDataURL:resumeDataURL];
			[downloader.progress subscribeNext:^(SQRLDownloadProgress *progress) {
				[self->_downloadProgress sendNext:progress];
			}];

			return [[[downloader
				downloadToURL:zipOutputURL]
				reduceEach:^(NSURLResponse *response, NSURL *zipURL) {
					if ([response isKindOfClass:NSHTTPURLResponse.class]) {
						NSHTTPURLResponse *httpResponse = (id)response;

						if (httpResponse.statusCode == 304 /* Not Modified */) {
							[NSFileManager.defaultManager removeItemAtURL:zipURL error:NULL];
							return [RACSignal return:nil];
						}

						if (!(httpResponse.statusCode >= 200 && httpResponse.statusCode <= 299)) {
							NSData *bodyData = [[NSFileHandle fileHandleForReadingFromURL:zipURL error:NULL] readDataOfLength:SQRLUpdaterServerDataErrorLimit] ?: NSData.data;
							[NSFileManager.defaultManager removeItemAtURL:zipURL error:NULL];

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

					NSLog(@"Download completed to: %@", zipURL);
					return [[self
						verifyFileAtURL:zipURL size:update.packageSize digest:update.packageDigest]
						then:^{
							return [self unarchiveAndPrepareZipAtURL:zipURL intoDirectory:downloadDirectory];
						}];
				}]
				flatten];
		}]
		setNameWithFormat:@"%@ -downloadBundleForUpdate: %@ intoDirectory: %@", self, update, downloadDirectory];
}

- (RACSignal *)verifyFileAtURL:(NSURL *)packageURL size:(NSNumber *)expectedSize digest:(NSString *)expectedDigest {
	NSParameterAssert(packageURL != nil);

	if (expectedSize == nil && expectedDigest == nil) return [RACSignal empty];

	return [[RACSignal
		defer:^{
			RACSignal * (^reject)(NSString *) = ^(NSString *reason) {
				[NSFileManager.defaultManager removeItemAtURL:packageURL error:NULL];

				NSDictionary *userInfo = @{
					NSLocalizedDescriptionKey: NSLocalizedString(@"Update download failed", nil),
					NSLocalizedRecoverySuggestionErrorKey: reason,
					NSURLErrorKey: packageURL,
				};
				return [RACSignal error:[NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorInvalidUpdatePackage userInfo:userInfo]];
			};

			if (expectedSize != nil) {
				NSNumber *size = nil;
				[packageURL getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
				if (![size isEqual:expectedSize]) {
					return reject([NSString stringWithFormat:NSLocalizedString(@"The downloaded file is %@ bytes, expected %@.", nil), size, expectedSize]);
				}
			}

			if (expectedDigest != nil) {
				NSInputStream *stream = [NSInputStream inputStreamWithURL:packageURL];
				[stream open];

				CC_SHA256_CTX context;
				CC_SHA256_Init(&context);
				uint8_t buffer[256 * 1024];
				NSInteger read;
				while ((read = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
					CC_SHA256_Update(&context, buffer, (CC_LONG)read);
				}
				NSError *readError = read < 0 ? stream.streamError : nil;
				[stream close];
				if (readError != nil) return [RACSignal error:readError];

				unsigned char digest[CC_SHA256_DIGEST_LENGTH];
				CC_SHA256_Final(digest, &context);
				NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
				for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];

				if (![hex isEqualToString:expectedDigest]) {
					return reject([NSString stringWithFormat:NSLocalizedString(@"The downloaded file digest is %@, expected %@.", nil), hex, expectedDigest]);
				}
			}

			return [RACSignal empty];
		}]
		setNameWithFormat:@"%@ -verifyFileAtURL: %@", self, packageURL];
}

#pragma mark File Management

- (RACSignal *)uniqueTemporaryDirectoryForUpdate {
	// Clean up any orphaned update directories before creating a new one.
	// This prevents disk usage from growing when checkForUpdates() is called
	// multiple times without the app restarting. The currently staged update
	// (referenced by ShipItState.plist) is always preserved so quitAndInstall
	// remains safe to call while a new check is in progress.
	return [[[[[self
		pruneOrphanedUpdateDirectories]
		ignoreValues]
		concat:[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];
			return [directoryManager storageURL];
		}]]
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
	return [[self
		pruneUpdateDirectories]
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
			return [self removeUpdateDirectoriesInStorageURL:storageURL excludingURL:nil];
		}]
		setNameWithFormat:@"%@ -prunedUpdateDirectories", self];
}

/// Lazily removes orphaned temporary directories upon subscription, always
/// preserving the directory currently referenced by ShipItState.plist so that
/// quitAndInstall remains safe to call mid-check.
///
/// Safe to call in any state. Sends each removed directory then completes on
/// an unspecified thread. Errors reading the staged request are swallowed
/// (treated as "nothing staged").
- (RACSignal *)pruneOrphanedUpdateDirectories {
	return [[[[[SQRLShipItRequest
		readUsingURL:self.shipItStateURL]
		map:^(SQRLShipItRequest *request) {
			// The request holds the URL to the staged .app bundle; its parent
			// is the update.XXXXXXX directory we must preserve.
			return [request.updateBundleURL URLByDeletingLastPathComponent];
		}]
		catch:^(NSError *error) {
			// No staged request (or unreadable) — nothing to preserve.
			return [RACSignal return:nil];
		}]
		flattenMap:^(NSURL *stagedDirectoryURL) {
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:SQRLShipItLauncher.shipItJobLabel];
			return [[directoryManager storageURL]
				flattenMap:^(NSURL *storageURL) {
					return [self removeUpdateDirectoriesInStorageURL:storageURL excludingURL:stagedDirectoryURL];
				}];
		}]
		setNameWithFormat:@"%@ -pruneOrphanedUpdateDirectories", self];
}

/// Shared enumerate-and-delete logic for update temp directories.
///
/// storageURL  - The Squirrel storage root to enumerate. Must not be nil.
/// excludedURL - Directory to skip (compared by standardized path). May be nil.
- (RACSignal *)removeUpdateDirectoriesInStorageURL:(NSURL *)storageURL excludingURL:(NSURL *)excludedURL {
	NSParameterAssert(storageURL != nil);

	NSFileManager *manager = [[NSFileManager alloc] init];
	NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:storageURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsSubdirectoryDescendants errorHandler:^(NSURL *URL, NSError *error) {
		NSLog(@"Error enumerating item %@ within directory %@: %@", URL, storageURL, error);
		return YES;
	}];

	NSString *excludedPath = excludedURL.URLByStandardizingPath.path;

	return [[enumerator.rac_sequence.signal
		filter:^(NSURL *enumeratedURL) {
			NSString *name = enumeratedURL.lastPathComponent;
			if (![name hasPrefix:SQRLUpdaterUniqueTemporaryDirectoryPrefix]) return NO;
			if (excludedPath != nil && [enumeratedURL.URLByStandardizingPath.path isEqualToString:excludedPath]) return NO;
			return YES;
		}]
		doNext:^(NSURL *directoryURL) {
			NSError *error = nil;
			if (![manager removeItemAtURL:directoryURL error:&error]) {
				NSLog(@"Error removing old update directory at %@: %@", directoryURL, error.sqrl_verboseDescription);
			}
		}];
}

#pragma mark Installing Updates

- (RACSignal *)verifyUpdate:(SQRLUpdate *)update fromBundle:(NSBundle *)updateBundle {
	NSParameterAssert(update != nil);
	NSParameterAssert(updateBundle != nil);

	return [[[self.signature
		verifyBundleAtURL:updateBundle.bundleURL]
		then:^{
			NSRunningApplication *currentApplication = NSRunningApplication.currentApplication;
			NSBundle *appBundle = [NSBundle bundleWithURL:currentApplication.bundleURL];
			BOOL preventDowngrades = [[appBundle objectForInfoDictionaryKey:@"ElectronSquirrelPreventDowngrades"] boolValue];

			if (preventDowngrades == YES) {
				NSString* currentVersion = [appBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
				NSString* updateVersion = [updateBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
				if (!currentVersion || !updateVersion) {
					NSDictionary *errorInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Cannot update to a bundle with a lower version number", nil),
						NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"The application has ElectronSquirrelPreventDowngrades enabled and is missing a valid version string in either the current bundle or the target bundle", nil),
					};
					NSError *error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorMissingUpdateBundle userInfo:errorInfo];
					return [RACSignal error:error];
				}

				if (!isVersionStandard(currentVersion)) {
					NSDictionary *errorInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Cannot update to a bundle with a lower version number", nil),
						NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"The application has ElectronSquirrelPreventDowngrades enabled and is trying to update from '%@' which is not a valid version string", nil), currentVersion],
					};
					NSError *error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorMissingUpdateBundle userInfo:errorInfo];
					return [RACSignal error:error];
				}

				if (!isVersionStandard(updateVersion)) {
					NSDictionary *errorInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Cannot update to a bundle with a lower version number", nil),
						NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"The application has ElectronSquirrelPreventDowngrades enabled and is trying to update to '%@' which is not a valid version string", nil), updateVersion],
					};
					NSError *error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorMissingUpdateBundle userInfo:errorInfo];
					return [RACSignal error:error];
				}

				if (![SQRLUpdater isVersionAllowedForUpdate:updateVersion from:currentVersion]) {
					NSDictionary *errorInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Cannot update to a bundle with a lower version number", nil),
						NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"The application has ElectronSquirrelPreventDowngrades enabled and is trying to update from '%@' to '%@' which appears to be a downgrade", nil), currentVersion, updateVersion],
					};
					NSError *error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorMissingUpdateBundle userInfo:errorInfo];
					return [RACSignal error:error];
				}
			}

			SQRLDownloadedUpdate *downloadedUpdate = [[SQRLDownloadedUpdate alloc] initWithUpdate:update bundle:updateBundle];
			return [RACSignal return:downloadedUpdate];
		}]
		setNameWithFormat:@"%@ -verifyUpdate: %@ fromBundle: %@", self, update, updateBundle];
}

- (RACSignal *)prepareUpdateForInstallation:(SQRLDownloadedUpdate *)update {
	NSParameterAssert(update != nil);

	return [[[[RACSignal
		defer:^{
			NSRunningApplication *currentApplication = NSRunningApplication.currentApplication;
			NSURL *targetBundleURL = currentApplication.bundleURL.URLByResolvingSymlinksInPath;
			NSBundle *appBundle = [NSBundle bundleWithURL:targetBundleURL];
			// Only use the update bundle's name if the user hasn't renamed the
			// app themselves.
			BOOL useUpdateBundleName = [appBundle.sqrl_executableName isEqual:targetBundleURL.lastPathComponent.stringByDeletingPathExtension];

			SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:update.bundle.bundleURL targetBundleURL:targetBundleURL bundleIdentifier:currentApplication.bundleIdentifier launchAfterInstallation:NO useUpdateBundleName:useUpdateBundleName];
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
