//
//  SQRLFileListener.h
//  Squirrel
//
//  Created by Keith Duncan on 17/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class RACSignal;

// Subscribes to file events for the given URL.
@interface SQRLFileListener : NSObject

// Wait for a file to appear at a file location.
//
// fileURL - URL to wait for, if the parent path doesn't already exist or isn't
//           a directory, an error is sent. Must not be nil.
//
// Returns a signal which completes when the file system object is present, or
// errors.
+ (RACSignal *)waitUntilItemExistsAtFileURL:(NSURL *)fileURL;

@end
