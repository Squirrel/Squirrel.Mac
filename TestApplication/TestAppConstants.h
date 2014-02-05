//
//  TestAppConstants.h
//  Squirrel
//
//  Created by Keith Duncan on 05/02/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// This notification is posted to the distributed notification center when a
// change to the `SQRLUpdater.state` property is observed.
//
// It is posted once on launch with the initial idle state, and then for any
// transition thereafter.
//
// Yhe user info dictionary includes the new state value under the
// `SQRLTestAppUpdaterStateKey` key.
extern NSString * const SQRLTestAppUpdaterStateTransitionNotificationName;

// The state of the updater, an NSNumber.
extern NSString * const SQRLTestAppUpdaterStateKey;
