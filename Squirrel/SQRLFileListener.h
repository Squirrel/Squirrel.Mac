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

// Designated initialiser.
//
// fileURL - The file system location to watch for events.
//
// Returns an initialised file listener.
- (instancetype)initWithFileURL:(NSURL *)fileURL;

// A signal which completes when the file system object is present.
@property (readonly, strong, nonatomic) RACSignal *waitUntilPresent;

@end
