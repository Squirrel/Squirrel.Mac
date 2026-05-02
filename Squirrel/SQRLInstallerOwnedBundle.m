//
//  SQRLInstallerOwnedBundle.m
//  Squirrel
//
//  Created by Keith Duncan on 08/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLInstallerOwnedBundle.h"

#import <ReactiveObjC/EXTKeyPathCoding.h>

@implementation SQRLInstallerOwnedBundle

- (instancetype)initWithOriginalURL:(NSURL *)originalURL temporaryURL:(NSURL *)temporaryURL codeSignature:(SQRLCodeSignature *)codeSignature {
	return [self initWithDictionary:@{
		@keypath(self.originalURL): originalURL,
		@keypath(self.temporaryURL): temporaryURL,
		@keypath(self.codeSignature): codeSignature,
	} error:NULL];
}

@end
