//
//  SQRLHTTPServer.h
//  Squirrel
//
//  Created by Keith Duncan on 03/12/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SQRLHTTPServer : NSObject

- (NSURL *)start:(NSError **)errorRef;
- (void)invalidate;

@property (copy, nonatomic) CFHTTPMessageRef (^responseBlock)(CFHTTPMessageRef request);

@end
