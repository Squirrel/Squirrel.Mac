//
//  SQRLTestHelper.m
//  Squirrel
//
//  Created by Matt Diephouse on 7/7/14.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLTestHelper.h"

#import <objc/runtime.h>

@implementation SQRLTestHelper

#pragma mark - Specta Methods

+ (void)afterEach {
	// Enumerate backwards, so later resources are cleaned up first.
	for (dispatch_block_t block in self.cleanupBlocks.reverseObjectEnumerator) {
		block();
	}
	[self.cleanupBlocks removeAllObjects];
}

#pragma mark - Public Methods

+ (void)addCleanupBlock:(dispatch_block_t)block {
	[self.cleanupBlocks addObject:[block copy]];
}

#pragma mark - Private Methods

+ (NSMutableArray *)cleanupBlocks {
	NSMutableArray *blocks = objc_getAssociatedObject(self, "sqrl_cleanupBlocks");
	if (blocks == nil) {
		blocks = [NSMutableArray array];
		objc_setAssociatedObject(self, "sqrl_cleanupBlocks", blocks, OBJC_ASSOCIATION_RETAIN);
	}
	return blocks;
}

@end
