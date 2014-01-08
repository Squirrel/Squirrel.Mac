//
//  SQRLInstallerOwnedBundle.h
//  Squirrel
//
//  Created by Keith Duncan on 08/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import <Mantle/Mantle.h>

@class SQRLCodeSignature;

// Tracks original and temporary locations of a bundle. Should be created and
// serialised before moving a bundle aside.
//
// Can be used to ensure new targetURL requests meet the original bundle at that
// location's code signature, even though it's been moved aside.
@interface SQRLInstallerOwnedBundle : MTLModel

// Designated initialiser.
//
// 
- (instancetype)initWithOriginalURL:(NSURL *)originalURL temporaryURL:(NSURL *)temporaryURL codeSignature:(SQRLCodeSignature *)codeSignature;

@property (readonly, copy, nonatomic) NSURL *originalURL;
@property (readonly, copy, nonatomic) NSURL *temporaryURL;
@property (readonly, copy, nonatomic) SQRLCodeSignature *codeSignature;

@end
