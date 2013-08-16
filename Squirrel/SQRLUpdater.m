//
//  SQRLUpdater.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdater.h"
#import "NSError+SQRLVerbosityExtensions.h"
#import "SQRLArguments.h"
#import "SQRLCodeSignatureVerifier.h"
#import "SQRLShipItLauncher.h"
#import "SQRLZipArchiver.h"

NSString * const SQRLUpdaterUpdateAvailableNotification = @"SQRLUpdaterUpdateAvailableNotification";
NSString * const SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey = @"SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey";
NSString * const SQRLUpdaterUpdateAvailableNotificationReleaseNameKey = @"SQRLUpdaterUpdateAvailableNotificationReleaseNameKey";
NSString * const SQRLUpdaterUpdateAvailableNotificationLulzURLKey = @"SQRLUpdaterUpdateAvailableNotificationLulzURLKey";

NSString * const SQRLUpdaterJSONURLKey = @"url";
NSString * const SQRLUpdaterJSONReleaseNotesKey = @"notes";
NSString * const SQRLUpdaterJSONNameKey = @"name";
NSString * const SQRLUpdaterJSONLulzURLKey = @"lulz";

NSString * const SQRLUpdaterErrorDomain = @"SQRLUpdaterErrorDomain";
const NSInteger SQRLUpdaterErrorNoUpdateWaiting = 1;
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

+ (instancetype)sharedUpdater {
	static SQRLUpdater *sharedInstance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sharedInstance = [[self alloc] init];
	});
	
	return sharedInstance;
}

- (instancetype)init {
	self = [super init];
	if (self == nil) return nil;
	
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
	[self _assertCanCheckForUpdates];

	dispatch_async(dispatch_get_main_queue(), ^{
		self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(checkForUpdates) userInfo:nil repeats:YES];
	});
}

#pragma mark Checking for Updates

- (void)_assertCanCheckForUpdates {
	NSParameterAssert(self.APIEndpoint != nil);
}

- (NSString *)OSVersionString {
	NSURL *versionPlistURL = [NSURL fileURLWithPath:@"/System/Library/CoreServices/SystemVersion.plist"];
	NSDictionary *versionPlist = [NSDictionary dictionaryWithContentsOfURL:versionPlistURL];
	return versionPlist[@"ProductUserVisibleVersion"];
}

- (void)checkForUpdates {
	[self _assertCanCheckForUpdates];

	if (getenv("DISABLE_UPDATE_CHECK") != NULL) return;
	
	if (self.state != SQRLUpdaterStateIdle) return; //We have a new update installed already, you crazy fool!
	self.state = SQRLUpdaterStateCheckingForUpdate;
	
	NSString *appVersion = NSBundle.mainBundle.infoDictionary[(id)kCFBundleVersionKey];
	NSString *OSVersion = self.OSVersionString;
	
	NSMutableString *requestString = [NSMutableString stringWithFormat:@"%@?version=%@&os_version=%@", self.APIEndpoint.absoluteString, [appVersion stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding], [OSVersion stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
	if (self.githubUsername.length > 0) {
		CFStringRef escapedUsername = CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)self.githubUsername, NULL, CFSTR("?=&/#,\\"), kCFStringEncodingUTF8);
		[requestString appendFormat:@"&username=%@", CFBridgingRelease(escapedUsername)];
	}
	
	NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:requestString]];
	[NSURLConnection sendAsynchronousRequest:request queue:self.updateQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
		NSDictionary *JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
		if (response == nil || ![JSON isKindOfClass:NSDictionary.class]) { //No updates for us
			NSLog(@"Instead of update information, server returned:\n%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);

			[self finishAndSetIdle];
			return;
		}
		
		NSString *urlString = JSON[SQRLUpdaterJSONURLKey];
		if (![urlString isKindOfClass:NSString.class]) { //Hmm… we got returned something without a URL, whatever it is… we aren't interested in it.
			NSLog(@"Update JSON is missing a URL: %@", JSON);

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
		
		NSURL *zipDownloadURL = [NSURL URLWithString:urlString];
		NSURL *zipOutputURL = [self.downloadFolder URLByAppendingPathComponent:zipDownloadURL.lastPathComponent];

		NSURLRequest *zipDownloadRequest = [NSURLRequest requestWithURL:zipDownloadURL];
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
			
			[SQRLZipArchiver unzipArchiveAtURL:zipOutputURL intoDirectoryAtURL:self.downloadFolder completion:^(BOOL unzipped) {
				if (!unzipped) {
					NSLog(@"Could not extract update.");
					[self finishAndSetIdle];
					return;
				}

				NSString *bundleIdentifier = NSRunningApplication.currentApplication.bundleIdentifier;
				NSBundle *updateBundle = [self applicationBundleWithIdentifier:bundleIdentifier inDirectory:self.downloadFolder];
				if (updateBundle == nil) {
					NSLog(@"Could not locate update bundle for %@ within %@", bundleIdentifier, self.downloadFolder);
					[self finishAndSetIdle];
					return;
				}

				NSError *error = nil;
				BOOL verified = [self.verifier verifyCodeSignatureOfBundle:updateBundle.bundleURL error:&error];
				if (!verified) {
					NSLog(@"Failed to validate the code signature for app update. Error: %@", error.sqrl_verboseDescription);
					[self finishAndSetIdle];
					return;
				}
				
				NSString *name = JSON[SQRLUpdaterJSONNameKey];
				if (![name isKindOfClass:NSString.class]) {
					NSLog(@"Ignoring release name of an unsupported type: %@", name);
					name = nil;
				}
				
				NSString *releaseNotes = JSON[SQRLUpdaterJSONReleaseNotesKey];
				if (![releaseNotes isKindOfClass:NSString.class]) {
					NSLog(@"Ignoring release notes of an unsupported type: %@", releaseNotes);
					releaseNotes = nil;
				}

				NSString *lulzURLString = JSON[SQRLUpdaterJSONLulzURLKey];
				NSURL *lulzURL = nil;
				if ([lulzURLString isKindOfClass:NSString.class]) {
					lulzURL = [NSURL URLWithString:lulzURLString];
				} else {
					NSLog(@"Ignoring lulz URL of an unsupported type: %@", lulzURLString);
				}

				if (lulzURL == nil) lulzURL = [self randomLulzURL];

				NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
				if (releaseNotes != nil) userInfo[SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey] = releaseNotes;
				if (name != nil) userInfo[SQRLUpdaterUpdateAvailableNotificationReleaseNameKey] = name;
				if (lulzURL != nil) userInfo[SQRLUpdaterUpdateAvailableNotificationLulzURLKey] = lulzURL;
				
				self.state = SQRLUpdaterStateAwaitingRelaunch;
				
				dispatch_async(dispatch_get_main_queue(), ^{
					[NSNotificationCenter.defaultCenter postNotificationName:SQRLUpdaterUpdateAvailableNotification object:self userInfo:userInfo];
				});
			}];
		}];
		
		self.state = SQRLUpdaterStateDownloadingUpdate;
	}];
}

- (NSURL *)randomLulzURL {
	NSArray *lulz = @[
		@"http://blog.lmorchard.com/wp-content/uploads/2013/02/well_done_sir.gif",
		@"http://i255.photobucket.com/albums/hh150/hayati_h2/tumblr_lfmpar9EUd1qdzjnp.gif",
		@"http://media.tumblr.com/tumblr_lv1j4x1pJM1qbewag.gif",
		@"http://i.imgur.com/UmpOi.gif",
	];

	return [NSURL URLWithString:lulz[arc4random_uniform(lulz.count)]];
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

- (NSBundle *)applicationBundleWithIdentifier:(NSString *)bundleIdentifier inDirectory:(NSURL *)directory {
	NSParameterAssert(bundleIdentifier != nil);

	if (directory == nil) return nil;

	NSFileManager *manager = [[NSFileManager alloc] init];
	NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:directory includingPropertiesForKeys:@[ NSURLTypeIdentifierKey ] options:NSDirectoryEnumerationSkipsPackageDescendants | NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^(NSURL *URL, NSError *error) {
		NSLog(@"Error enumerating item %@ within directory %@: %@", URL, directory, error);
		return YES;
	}];

	for (NSURL *URL in enumerator) {
		NSString *type = nil;
		NSError *error = nil;
		if (![URL getResourceValue:&type forKey:NSURLTypeIdentifierKey error:&error]) {
			NSLog(@"Error retrieving UTI for item at %@: %@", URL, error);
			continue;
		}

		if (!UTTypeConformsTo((__bridge CFStringRef)type, kUTTypeApplicationBundle)) continue;

		NSBundle *bundle = [NSBundle bundleWithURL:URL];
		if (bundle == nil) {
			NSLog(@"Could not open application bundle at %@", URL);
			continue;
		}

		if ([bundle.bundleIdentifier isEqual:bundleIdentifier]) {
			return bundle;
		}
	}

	return nil;
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

- (void)installUpdateIfNeeded:(void (^)(BOOL success, NSError *error))completionHandler {
	__typeof__(completionHandler) originalHandler = [completionHandler copy];

	completionHandler = ^(BOOL success, NSError *error) {
		if (!success) [self finishAndSetIdle];
		originalHandler(success, error);
	};

	if (self.state != SQRLUpdaterStateAwaitingRelaunch) {
		NSDictionary *userInfo = @{
			NSLocalizedDescriptionKey: NSLocalizedString(@"No update to install", nil),
		};

		completionHandler(NO, [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorNoUpdateWaiting userInfo:userInfo]);
		return;
	}
	
	NSRunningApplication *currentApplication = NSRunningApplication.currentApplication;
	NSBundle *updateBundle = [self applicationBundleWithIdentifier:currentApplication.bundleIdentifier inDirectory:self.downloadFolder];
	if (updateBundle == nil) {
		NSDictionary *userInfo = @{
			NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not locate update bundle for %@ within %@", nil), currentApplication.bundleIdentifier, self.downloadFolder],
		};

		completionHandler(NO, [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorMissingUpdateBundle userInfo:userInfo]);
		return;
	}

	NSData *requirementData = self.verifier.requirementData;
	if (requirementData == nil) {
		NSDictionary *userInfo = @{
			NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not load code signing requirement for %@", nil), currentApplication.bundleIdentifier],
		};

		completionHandler(NO, [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorRetrievingCodeSigningRequirement userInfo:userInfo]);
		return;
	}

	SQRLShipItLauncher *launcher = [[SQRLShipItLauncher alloc] init];

	NSError *error = nil;
	xpc_connection_t connection = [launcher launch:&error];
	if (connection == NULL) {
		completionHandler(NO, error);
		return;
	}
	
	[NSProcessInfo.processInfo disableSuddenTermination];

	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	@onExit {
		xpc_release(message);
	};

	xpc_dictionary_set_string(message, SQRLShipItCommandKey, SQRLShipItInstallCommand);
	xpc_dictionary_set_string(message, SQRLTargetBundleURLKey, currentApplication.bundleURL.absoluteString.UTF8String);
	xpc_dictionary_set_string(message, SQRLUpdateBundleURLKey, updateBundle.bundleURL.absoluteString.UTF8String);
	xpc_dictionary_set_string(message, SQRLBackupURLKey, self.applicationSupportURL.absoluteString.UTF8String);
	xpc_dictionary_set_bool(message, SQRLShouldRelaunchKey, self.shouldRelaunch);
	xpc_dictionary_set_bool(message, SQRLWaitForConnectionKey, true);
	xpc_dictionary_set_data(message, SQRLCodeSigningRequirementKey, requirementData.bytes, requirementData.length);

	xpc_connection_resume(connection);
	xpc_connection_send_message_with_reply(connection, message, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(xpc_object_t reply) {
		BOOL success = xpc_dictionary_get_bool(reply, SQRLShipItSuccessKey);
		NSError *error = nil;
		if (!success) {
			const char *errorStr = xpc_dictionary_get_string(reply, SQRLShipItErrorKey);
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: @(errorStr) ?: NSLocalizedString(@"An unknown error occurred within ShipIt", nil),
			};

			error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorPreparingUpdateJob userInfo:userInfo];
			[NSProcessInfo.processInfo enableSuddenTermination];
		}

		completionHandler(success, error);
	});
}

@end

