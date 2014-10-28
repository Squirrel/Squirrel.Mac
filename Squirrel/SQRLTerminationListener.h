//
//  SQRLTerminationListener.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-04.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class RACSignal;

// Waits for the termination of a GUI application.
@interface SQRLTerminationListener : NSObject

// Initializes the receiver to wait for termination of the app at the given
// location.
//
// bundleURL - The URL to the application bundle to watch. This must not be nil.
// bundleID  - The identifier of the application bundle to watch. This must not
//             be nil.
- (id)initWithURL:(NSURL *)bundleURL bundleIdentifier:(NSString *)bundleID;

// Lazily waits for termination of all instances of the application identified
// at initialization.
//
// Returns a signal which send an `NSRunningApplication` for each instance of the
// application that is being watched (before the instance terminates), then
// completes on a background scheduler.
- (RACSignal *)waitForTermination;

@end
