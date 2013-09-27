//
//  Squirrel-Constants.h
//  Squirrel
//
//  Created by Keith Duncan on 27/09/2013.
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
