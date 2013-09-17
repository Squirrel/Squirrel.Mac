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

// Associated with a string containing the release name for the available
// update.
extern NSString * const SQRLUpdaterUpdateAvailableNotificationReleaseNameKey;

// Associated with an NSDate representing the day that the release became
// available.
extern NSString * const SQRLUpdaterUpdateAvailableNotificationReleaseDateKey;

// Asscociated with a string containing the bundle version for the available
// update.
extern NSString * const SQRLUpdaterUpdateAvailableNotificationBundleVersionKey;

// Associated with an NSURL to a side-splittingly hilarious image to show for
// the available update.
extern NSString * const SQRLUpdaterUpdateAvailableNotificationLulzURLKey;

// The domain for errors originating within SQRLUpdater.
extern NSString * const SQRLUpdaterErrorDomain;

// There is no update to be installed from -installUpdateIfNeeded:.
extern const NSInteger SQRLUpdaterErrorNoUpdateWaiting;

// The downloaded update does not contain an app bundle, or it was deleted on
// disk before we could get to it.
extern const NSInteger SQRLUpdaterErrorMissingUpdateBundle;

// An error occurred in the out-of-process updater while it was setting up.
extern const NSInteger SQRLUpdaterErrorPreparingUpdateJob;

// The code signing requirement for the running application could not be
// retrieved.
extern const NSInteger SQRLUpdaterErrorRetrievingCodeSigningRequirement;

// Downloads and installs updates from GitHub.com The Website.
@interface SQRLUpdater : NSObject

// The current state of the manager.
//
// This property is KVO-compliant.
@property (atomic, readonly) SQRLUpdaterState state;

// Whether or not to relaunch after installing an update.
//
// This will be reset to NO whenever update installation fails.
@property (atomic) BOOL shouldRelaunch;

// The request that will be sent to check for updates.
//
// The default value is the argument that was originally passed to
// -initWithUpdateRequest:.
//
// This property must never be set to nil.
@property (atomic, copy) NSURLRequest *updateRequest;

// Initializes an updater that will send the given request to check for updates.
//
// This is the designated initializer for this class.
//
// updateRequest - A request to send to check for updates. This request can be
//                 customized as desired, like by including an `Authorization`
//                 header to authenticate with a private update server, or
//                 pointing to a local URL for testing. This must not be nil.
//
// Returns the initialized `SQRLUpdater`.
- (id)initWithUpdateRequest:(NSURLRequest *)updateRequest;

// If one isn't already running, kicks off a check for updates.
//
// After the successful installation of an update, an
// `SQRLUpdaterUpdateAvailableNotificationName` will be posted.
- (void)checkForUpdates;

// Schedules an update check every `interval` seconds. The first check will not
// occur until `interval` seconds have passed.
//
// interval - The interval, in seconds, between each check.
- (void)startAutomaticChecksWithInterval:(NSTimeInterval)interval;

// Enqueues a job that will install a previously downloaded, unzipped, and verified
// update after the app quits.
//
// This will disable sudden termination if the job is enqueued successfully.
//
// If `shouldRelaunch` is YES, the app will be launched back up after the update
// is installed successfully.
//
// completionHandler - A block to invoke when updating in place has completed or failed.
//                     The app should immediately terminate once this block is invoked.
- (void)installUpdateIfNeeded:(void (^)(BOOL success, NSError *error))completionHandler;

@end

@interface SQRLUpdater (Unavailable)

- (id)init __attribute__((unavailable("Use -initWithUpdateRequest: instead")));

@end
