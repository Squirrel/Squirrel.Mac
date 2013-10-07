//
//  SQRLStateManager+Private.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-07.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLStateManager.h"

@interface SQRLStateManager ()

// Returns the URL at which on-disk state will be saved for the given
// application identifier.
+ (NSURL *)stateURLWithIdentifier:(NSString *)identifier;

@end
