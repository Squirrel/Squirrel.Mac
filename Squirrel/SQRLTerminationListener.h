//
//  SQRLTerminationListener.h
//  Squirrel
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// Waits for the parent process to terminate.
@interface SQRLTerminationListener : NSObject

// Initializes the receiver to watch for the termination of the specified
// process.
//
// Note that termination is not actually noticed until after -beginListening has
// been invoked.
//
// processID          - The PID of the process to watch for termination. This
//                      process must be the parent of the `shipit` process.
// bundleIdentifier   - The bundle identifier of the application to watch for
//                      termination. This must not be nil.
// bundleURL          - The URL of the application to watch for termination.
//                      This must not be nil.
// terminationHandler - A block to invoke once the watched process terminates.
//                      This must not be nil.
//
// Returns an initialized listener, or nil if an error occurs.
- (id)initWithProcessID:(pid_t)processID bundleIdentifier:(NSString *)bundleIdentifier bundleURL:(NSURL *)bundleURL terminationHandler:(void (^)(void))terminationHandler;

// Starts watching the target process for termination.
//
// If the target process has already terminated by the time this method is
// invoked, the `terminationHandler` is called immediately.
//
// This should only be invoked once.
- (void)beginListening;

@end
