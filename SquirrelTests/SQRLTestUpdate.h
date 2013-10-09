//
//  SQRLTestUpdate.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Squirrel/Squirrel.h>

@interface SQRLTestUpdate : SQRLUpdate

// Whether this update should actually be installed by the test application.
//
// Associated with an `is_final` JSON key.
@property (nonatomic, assign, getter = isFinal, readonly) BOOL final;

@end
