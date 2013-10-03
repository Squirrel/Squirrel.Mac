//
//  NSUserDefaults+ShipItExtensions.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-02.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "NSUserDefaults+ShipItExtensions.h"

static NSString * const SQRLTargetBundleKey = @"SQRLTargetBundleKey";
static NSString * const SQRLUpdateBundleKey = @"SQRLUpdateBundleKey";
static NSString * const SQRLBackupBundleKey = @"SQRLBackupBundleKey";
static NSString * const SQRLApplicationSupportKey = @"SQRLApplicationSupportKey";
static NSString * const SQRLRequirementDataKey = @"SQRLRequirementDataKey";
static NSString * const SQRLStateKey = @"SQRLStateKey";
static NSString * const SQRLBundleIdentifierKey = @"SQRLBundleIdentifierKey";

@implementation NSUserDefaults (ShipItExtensions)

// Safer than -URLForKey: because we explicitly disallow anything but file path
// URLs.
- (NSURL *)sqrl_fileURLForKey:(NSString *)key {
	NSParameterAssert(key != nil);
	return [NSURL fileURLWithPath:[self stringForKey:key]];
}

- (void)sqrl_setFileURL:(NSURL *)fileURL forKey:(NSString *)key {
	NSParameterAssert(key != nil);

	if (fileURL == nil) {
		[self removeObjectForKey:SQRLTargetBundleKey];
	} else {
		NSString *path = fileURL.filePathURL.path;
		NSAssert(path != nil, @"URL does not point to a file path: %@", fileURL);

		[self setObject:path forKey:key];
	}
}

- (NSURL *)sqrl_targetBundleURL {
	return [self sqrl_fileURLForKey:SQRLTargetBundleKey];
}

- (void)setSqrl_targetBundleURL:(NSURL *)fileURL {
	[self sqrl_setFileURL:fileURL forKey:SQRLTargetBundleKey];
}

- (NSURL *)sqrl_updateBundleURL {
	return [self sqrl_fileURLForKey:SQRLUpdateBundleKey];
}

- (void)setSqrl_updateBundleURL:(NSURL *)fileURL {
	[self sqrl_setFileURL:fileURL forKey:SQRLUpdateBundleKey];
}

- (NSURL *)sqrl_backupBundleURL {
	return [self sqrl_fileURLForKey:SQRLBackupBundleKey];
}

- (void)setSqrl_backupBundleURL:(NSURL *)fileURL {
	[self sqrl_setFileURL:fileURL forKey:SQRLBackupBundleKey];
}

- (NSURL *)sqrl_applicationSupportURL {
	return [self sqrl_fileURLForKey:SQRLApplicationSupportKey];
}

- (void)setSqrl_applicationSupportURL:(NSURL *)fileURL {
	[self sqrl_setFileURL:fileURL forKey:SQRLApplicationSupportKey];
}

- (NSData *)sqrl_requirementData {
	return [self dataForKey:SQRLRequirementDataKey];
}

- (void)setSqrl_requirementData:(NSData *)data {
	if (data == nil) {
		[self removeObjectForKey:SQRLRequirementDataKey];
	} else {
		NSParameterAssert([data isKindOfClass:NSData.class]);
		[self setObject:data forKey:SQRLRequirementDataKey];
	}
}

- (SQRLShipItState)sqrl_state {
	return [self integerForKey:SQRLStateKey];
}

- (void)setSqrl_state:(SQRLShipItState)state {
	[self setInteger:state forKey:SQRLStateKey];

	if (![self synchronize]) {
		NSLog(@"Failed to synchronize user defaults %@", self);
	}
}

- (NSString *)sqrl_bundleIdentifier {
	return [self stringForKey:SQRLBundleIdentifierKey];
}

- (void)setSqrl_bundleIdentifier:(NSString *)identifier {
	if (identifier == nil) {
		[self removeObjectForKey:SQRLBundleIdentifierKey];
	} else {
		NSParameterAssert([identifier isKindOfClass:NSString.class]);
		[self setObject:identifier forKey:SQRLBundleIdentifierKey];
	}
}

@end
