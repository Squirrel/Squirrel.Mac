//
//  NSProcessInfo+SQRLVersionExtensions.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-09-16.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "NSProcessInfo+SQRLVersionExtensions.h"

@implementation NSProcessInfo (SQRLVersionExtensions)

- (NSString *)sqrl_operatingSystemShortVersionString {
	NSURL *versionPlistURL = [NSURL fileURLWithPath:@"/System/Library/CoreServices/SystemVersion.plist"];
	NSDictionary *versionPlist = [NSDictionary dictionaryWithContentsOfURL:versionPlistURL];
	return versionPlist[@"ProductUserVisibleVersion"];
}

@end
