//
//  NSBundle+SQRLVersionExtensions.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-09-25.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "NSBundle+SQRLVersionExtensions.h"

@implementation NSBundle (SQRLVersionExtensions)

- (NSString *)sqrl_bundleVersion {
	return [self objectForInfoDictionaryKey:(id)kCFBundleVersionKey];
}

- (NSString *)sqrl_executableName {
	return [self objectForInfoDictionaryKey:(id)kCFBundleExecutableKey];
}

@end
