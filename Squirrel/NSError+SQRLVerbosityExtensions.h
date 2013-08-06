//
//  NSError+SQRLVerbosityExtensions.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-05.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSError (SQRLVerbosityExtensions)

// Returns a description of the receiver, without holding back. Includes all
// `userInfo` keys, and verbosely describes underlying errors recursively.
- (NSString *)sqrl_verboseDescription;

@end
