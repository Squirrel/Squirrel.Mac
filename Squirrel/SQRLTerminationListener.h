//
//  SQRLTerminationListener.h
//  Squirrel
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface SQRLTerminationListener : NSObject

- (id)initWithProcessID:(pid_t)processID bundleIdentifier:(NSString *)bundleIdentifier bundleURL:(NSURL *)bundleURL terminationHandler:(void (^)(void))terminationHandler;

@end
