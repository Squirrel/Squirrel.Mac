//
//  SQRLUpdater.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

// An enum used to represent the state of the updater.
//
// SQRLUpdaterStateIdle              - Doing absolutely diddly squat.
// SQRLUpdaterStateCheckingForUpdate - Requesting any updates from central.
// SQRLUpdaterStateDownloadingUpdate - Update found, downloading the .zip.
// SQRLUpdaterStateUnzippingUpdate   - Unzipping the .app.
// SQRLUpdaterStateAwaitingRelaunch  - Awaiting a relaunch to install
//                                         the update.
typedef enum : NSUInteger {
	SQRLUpdaterStateIdle,
	SQRLUpdaterStateCheckingForUpdate,
	SQRLUpdaterStateDownloadingUpdate,
	SQRLUpdaterStateUnzippingUpdate,
	SQRLUpdaterStateAwaitingRelaunch,
} SQRLUpdaterState;

// Posted when an update is available to be installed.
//
// The `userInfo` will contain one
// `SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey` typed as a
// string, and one `SQRLUpdaterUpdateAvailableNotificationReleaseNameKey`
// also typed as string.
extern NSString *const SQRLUpdaterUpdateAvailableNotification;
extern NSString *const SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey;
extern NSString *const SQRLUpdaterUpdateAvailableNotificationReleaseNameKey;
extern NSString * const SQRLUpdaterUpdateAvailableNotificationLulzURLKey;

extern NSString * const SQRLUpdaterErrorDomain;

// An error occurred validating the code signature of a downloaded update.
extern const NSInteger SQRLUpdaterErrorCodeSigning;

// A singleton dedicated to downloading and installing updates from central.
@interface SQRLUpdater : NSObject

@property (nonatomic, copy) NSString *githubUsername;

// The current state of the manager. Observable.
@property (atomic, readonly) SQRLUpdaterState state;

// Whether or not to relaunch after installing an update.
@property (nonatomic, readwrite) BOOL shouldRelaunch;

// Returns the singleton instance.
+ (instancetype)sharedUpdater;

// If one isn't already running, kicks off a check for updates against central.
//
// If an update is found, an `SQRLUpdaterUpdateFoundNotificationName`
// notification will be posted before installation. After a successful
// installation an `SQRLUpdaterUpdateInstalledNotificationName` will be
// posted.
- (void)checkForUpdates;

// Schedules an update check every `interval` seconds. The first check will not
// occur until `interval` seconds have passed.
//
// interval - The interval, in seconds, between each check.
- (void)startAutomaticChecksWithInterval:(NSTimeInterval)interval;

// Instructs the Sparkle relauncher to install a previously downloaded,
// unzipped and verified app update.
//
// The update won't be installed until the app has been terminated.
- (void)installUpdateIfNeeded;

// Verifies the code signature of the specified bundle, which must be signed in
// the same way as the running application.
//
// Returns NO if the bundle's code signature could not be verified, and the
// error parameter will contain the specific error.
- (BOOL)verifyCodeSignatureOfBundle:(NSBundle *)bundle error:(NSError **)error;

@end
