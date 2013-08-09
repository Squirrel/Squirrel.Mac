//
//  SQRLUpdater.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

// Represents the current state of the updater.
//
// SQRLUpdaterStateIdle              - Doing absolutely diddly squat.
// SQRLUpdaterStateCheckingForUpdate - Checking for any updates from the server.
// SQRLUpdaterStateDownloadingUpdate - Update found, downloading the .zip.
// SQRLUpdaterStateUnzippingUpdate   - Unzipping the .app.
// SQRLUpdaterStateAwaitingRelaunch  - Awaiting a relaunch to install
//                                     the update.
typedef enum : NSUInteger {
	SQRLUpdaterStateIdle,
	SQRLUpdaterStateCheckingForUpdate,
	SQRLUpdaterStateDownloadingUpdate,
	SQRLUpdaterStateUnzippingUpdate,
	SQRLUpdaterStateAwaitingRelaunch,
} SQRLUpdaterState;

// Posted when an update is available to be installed.
extern NSString * const SQRLUpdaterUpdateAvailableNotification;

// Associated with a string containing the release notes for the available
// update.
extern NSString * const SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey;

// Associated with a string containing the release name for the available update.
extern NSString * const SQRLUpdaterUpdateAvailableNotificationReleaseNameKey;

// Associated with an NSURL to a side-splittingly hilarious image to show for
// the available update.
extern NSString * const SQRLUpdaterUpdateAvailableNotificationLulzURLKey;

// Downloads and installs updates from GitHub.com The Website.
@interface SQRLUpdater : NSObject

// The GitHub username for the current user of the app, if any.
//
// This is used to check for prerelease software that the user may be able to
// see.
@property (nonatomic, copy) NSString *githubUsername;

// The current state of the manager.
//
// This property is KVO-compliant.
@property (atomic, readonly) SQRLUpdaterState state;

// Whether or not to relaunch after installing an update.
//
// This will be reset to NO whenever update installation fails.
@property (atomic, readwrite) BOOL shouldRelaunch;

// The API endpoint from which to receive information about updates.
//
// This can be set to a local URL for testing.
@property (atomic, copy) NSURL *APIEndpoint;

// Returns the singleton updater.
+ (instancetype)sharedUpdater;

// If one isn't already running, kicks off a check for updates against central.
//
// After the successful installation of an update, an
// `SQRLUpdaterUpdateAvailableNotificationName` will be posted.
- (void)checkForUpdates;

// Schedules an update check every `interval` seconds. The first check will not
// occur until `interval` seconds have passed.
//
// interval - The interval, in seconds, between each check.
- (void)startAutomaticChecksWithInterval:(NSTimeInterval)interval;

// Enqueues a job that will wait for the app to terminate, then install a
// previously downloaded, unzipped, and verified update.
//
// If `shouldRelaunch` is YES, the app will be launched back up after the update
// is installed successfully.
- (void)installUpdateIfNeeded;

@end
