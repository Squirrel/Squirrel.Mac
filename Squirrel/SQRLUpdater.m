//
//  SQRLUpdater.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdater.h"

#import "AFJSONRequestOperation.h"
#import "SSZipArchive.h"
#import "SQRLCodeSignatureVerfication.h"

NSSTRING_CONST(SQRLUpdaterUpdateAvailableNotification);
NSSTRING_CONST(SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey);
NSSTRING_CONST(SQRLUpdaterUpdateAvailableNotificationReleaseNameKey);
NSSTRING_CONST(SQRLUpdaterUpdateAvailableNotificationLulzURLKey);

static NSString *const SQRLUpdaterAPIEndpoint = @"https://central.github.com/api/mac/latest";
static NSString *const SQRLUpdaterJSONURLKey = @"url";
static NSString *const SQRLUpdaterJSONReleaseNotesKey = @"notes";
static NSString *const SQRLUpdaterJSONNameKey = @"name";

@interface SQRLUpdater ()

@property (atomic, readwrite) SQRLUpdaterState state;
@property (nonatomic, readonly) NSOperationQueue *updateQueue;
@property (nonatomic, strong) NSTimer *updateTimer;

@property (nonatomic, strong) NSURL *downloadFolder;

@end

@implementation SQRLUpdater

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
	self.shouldRelaunch = NO;
    
	return self;
}

#pragma mark - Update Timer

- (void)setUpdateTimer:(NSTimer *)updateTimer {
	if (self.updateTimer == updateTimer) return;
	[self.updateTimer invalidate];
	_updateTimer = updateTimer;
}

- (void)startAutomaticChecksWithInterval:(NSTimeInterval)interval {
	@weakify(self);
	dispatch_async(dispatch_get_main_queue(), ^{
		@strongify(self)
        if (self == nil) return;
		self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(checkForUpdates) userInfo:nil repeats:YES];
	});
}

#pragma mark - System Information


- (NSURL *)applicationSupportURL {
    NSString *path = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    path = (paths.count > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    
    NSString * appDirectoryName = NSBundle.mainBundle.bundleIdentifier;
	NSURL *appSupportURL = [[NSURL fileURLWithPath:path] URLByAppendingPathComponent:appDirectoryName];
	
	NSFileManager *fileManager = [[NSFileManager alloc] init];
	if(![fileManager fileExistsAtPath:[appSupportURL path]]) {
		NSError *error = nil;
		BOOL success = [fileManager createDirectoryAtPath:[appSupportURL path] withIntermediateDirectories:YES attributes:nil error:&error];
		if(!success) {
			NSLog(@"Error: %@", error);
		}
	}
	
	return appSupportURL;
}

- (NSString *)OSVersionString {
	NSURL *versionPlistURL = [NSURL fileURLWithPath:@"/System/Library/CoreServices/SystemVersion.plist"];
	NSDictionary *versionPlist = [NSDictionary dictionaryWithContentsOfURL:versionPlistURL];
	return versionPlist[@"ProductUserVisibleVersion"];
}

#pragma mark - Checking

- (void)checkForUpdates {
	if (getenv("DISABLE_UPDATE_CHECK") != NULL) return;
    
	if (self.state != SQRLUpdaterStateIdle) return; //We have a new update installed already, you crazy fool!
	self.state = SQRLUpdaterStateCheckingForUpdate;
	
	NSString *appVersion = NSBundle.mainBundle.infoDictionary[(id)kCFBundleVersionKey];
	NSString *OSVersion = [self OSVersionString];
    
	NSMutableString *requestString = [NSMutableString stringWithFormat:@"%@?version=%@&os_version=%@", SQRLUpdaterAPIEndpoint, appVersion, OSVersion];
	if (self.githubUsername.length > 0) {
		[requestString appendFormat:@"&username=%@", self.githubUsername];
	}
	
	NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:requestString]];
	@weakify(self);
	AFJSONRequestOperation *updateCheckOperation = [AFJSONRequestOperation JSONRequestOperationWithRequest:request success:^(NSURLRequest *request, NSHTTPURLResponse *response, NSDictionary *JSON) {
		@strongify(self);
		
		if (response == nil || ![JSON isKindOfClass:NSDictionary.class]) { //No updates for us
			[self finishAndSetIdle];
			return;
		}
		
		NSString *urlString = JSON[SQRLUpdaterJSONURLKey];
		if (urlString == nil) { //Hmm… we got returned something without a URL, whatever it is… we aren't interested in it.
			[self finishAndSetIdle];
			return;
		}
		NSFileManager *fileManager = NSFileManager.defaultManager;
		
		NSString *tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.github.github"];
		NSError *directoryCreationError = nil;
		if (![fileManager createDirectoryAtURL:[NSURL fileURLWithPath:tempDirectory] withIntermediateDirectories:YES attributes:nil error:&directoryCreationError]) {
			NSLog(@"Could not create directory at: %@ because of: %@", self.downloadFolder, directoryCreationError);
			[self finishAndSetIdle];
			return;
		}
        
		NSString *tempDirectoryTemplate = [tempDirectory stringByAppendingPathComponent:@"update.XXXXXXX"];
		
		const char *tempDirectoryTemplateCString = [tempDirectoryTemplate fileSystemRepresentation];
		char *tempDirectoryNameCString = (char *)calloc(strlen(tempDirectoryTemplateCString) + 1, sizeof(char));
		strncpy(tempDirectoryNameCString, tempDirectoryTemplateCString, strlen(tempDirectoryTemplateCString));
		
		char *result = mkdtemp(tempDirectoryNameCString);
		if (result == NULL) {
			NSLog(@"Could not create temporary directory. Bailing."); //this would be bad
			[self finishAndSetIdle];
			return;
		}
		
		NSString *tempDirectoryPath = [fileManager stringWithFileSystemRepresentation:tempDirectoryNameCString length:strlen(result)];
		free(tempDirectoryNameCString);
		
		NSString *releaseNotes = JSON[SQRLUpdaterJSONReleaseNotesKey];
        
		NSString *lulzURLString = JSON[@"lulz"] ?: [self randomLulzURLString];
		
		self.downloadFolder = [NSURL fileURLWithPath:tempDirectoryPath];
		
		NSURL *zipDownloadURL = [NSURL URLWithString:urlString];
		NSURL *zipOutputURL = [self.downloadFolder URLByAppendingPathComponent:zipDownloadURL.lastPathComponent];
        
		NSOutputStream *zipStream = [[NSOutputStream alloc] initWithURL:zipOutputURL append:NO];
		NSURLRequest *zipDownloadRequest = [NSURLRequest requestWithURL:zipDownloadURL];
		AFHTTPRequestOperation *zipDownloadOperation = [[AFHTTPRequestOperation alloc] initWithRequest:zipDownloadRequest];
		[zipDownloadOperation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
			@strongify(self);
			NSLog(@"Download completed to: %@", zipOutputURL);
			self.state = SQRLUpdaterStateUnzippingUpdate;
            
            NSURL *destinationURL = zipOutputURL.URLByDeletingLastPathComponent;
            
            BOOL unzipped = [SSZipArchive unzipFileAtPath:zipOutputURL.path toDestination:destinationURL.path];
            
            if (!unzipped) {
                NSLog(@"Could not extract update.");
                [self finishAndSetIdle];
                return;
            }
            
            NSString *bundlePath = [destinationURL.path stringByAppendingPathComponent:@"GitHub.app"];
            NSBundle *downloadedBundle = [NSBundle bundleWithPath:bundlePath];
            if (downloadedBundle == nil) {
                NSLog(@"Could not create a bundle from %@", bundlePath);
                [self finishAndSetIdle];
                return;
            }
            
            NSError *error = nil;
            BOOL verified = [SQRLCodeSignatureVerfication verifyCodeSignatureOfBundle:downloadedBundle error:&error];

            if (!verified) {
                NSLog(@"Failed to validate the code signature for app update. Error: %@", error);
                 [self finishAndSetIdle];
                return;
            }
        
             NSLog(@"Code signature passed for %@", bundlePath);
             
             NSString *name = JSON[SQRLUpdaterJSONNameKey];
             NSDictionary *userInfo = @{
                SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey: releaseNotes,
                SQRLUpdaterUpdateAvailableNotificationReleaseNameKey: name,
                SQRLUpdaterUpdateAvailableNotificationLulzURLKey: [NSURL URLWithString:lulzURLString],
            };
             
            self.state = SQRLUpdaterStateAwaitingRelaunch;
             
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:SQRLUpdaterUpdateAvailableNotification object:self userInfo:userInfo];
            });
		} failure:nil];
		
		zipDownloadOperation.outputStream = zipStream;
		self.state = SQRLUpdaterStateDownloadingUpdate;
		[NSOperationQueue.currentQueue addOperation:zipDownloadOperation];
	} failure:nil]; //This isn't a critical operation so we can just fail silently. They may well be without internet connection
	
	[self.updateQueue addOperation:updateCheckOperation];
}

- (NSString *)randomLulzURLString {
	NSArray *lulz = @[
                      @"http://blog.lmorchard.com/wp-content/uploads/2013/02/well_done_sir.gif",
                      @"http://i255.photobucket.com/albums/hh150/hayati_h2/tumblr_lfmpar9EUd1qdzjnp.gif",
                      @"http://media.tumblr.com/tumblr_lv1j4x1pJM1qbewag.gif",
                      @"http://i.imgur.com/UmpOi.gif",
                      ];
	return lulz[arc4random() % lulz.count];
}

- (void)finishAndSetIdle {
	if (self.downloadFolder != nil) {
		NSError *deleteError = nil;
		if (![NSFileManager.defaultManager removeItemAtURL:self.downloadFolder error:&deleteError]) {
			NSLog(@"Error removing downloaded update at %@, error: %@", self.downloadFolder, deleteError);
		}
		
		self.downloadFolder = nil;
	}
	
	self.shouldRelaunch = NO;
	self.state = SQRLUpdaterStateIdle;
}

- (void)installUpdateIfNeeded {
	if (self.state != SQRLUpdaterStateAwaitingRelaunch || self.downloadFolder == nil) return;
	
	NSBundle *bundle = [NSBundle bundleForClass:self.class];
    
	NSURL *relauncherURL = [bundle URLForResource:@"Shipit" withExtension:nil];
	NSURL *targetURL = [self.applicationSupportURL URLByAppendingPathComponent:@"Shipit"];
	NSError *error = nil;
	NSLog(@"Copying relauncher from %@ to %@", relauncherURL.path, targetURL.path);
	
	if (![NSFileManager.defaultManager createDirectoryAtURL:targetURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]) {
		NSLog(@"Error installing update, failed to create App Support folder with error %@", error);
		[self finishAndSetIdle];
		return;
	}
    
    [NSFileManager.defaultManager removeItemAtURL:targetURL error:NULL];
    
    if (![NSFileManager.defaultManager copyItemAtURL:relauncherURL toURL:targetURL error:&error]) {
		NSLog(@"Error installing update, failed to copy relauncher %@", error);
		[self finishAndSetIdle];
		return;
	}
    
    NSRunningApplication *currentApplication = NSRunningApplication.currentApplication;

	[NSTask launchedTaskWithLaunchPath:targetURL.path arguments:@[
        // Path to host bundle
        currentApplication.bundleURL.path,
        // Wait for this PID to terminate before updating.
        [NSString stringWithFormat:@"%d", currentApplication.processIdentifier],
        // Where to find the update.
        self.downloadFolder.path,
        // relaunch after updating?
        self.shouldRelaunch ? @"1" : @"0",
    ]];
}

@end

