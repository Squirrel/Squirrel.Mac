//
//  SQRLTestHelper.h
//  Squirrel
//
//  Created by Matt Diephouse on 7/7/14.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

/// A test helper class that will run cleanup blocks after each test finishes.
@interface SQRLTestHelper : NSObject

/// Adds a cleanup block that will run after the next test completes.
+ (void)addCleanupBlock:(dispatch_block_t)block;

@end
