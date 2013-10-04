//
//  NSUserDefaults+SQRLShipItExtensions.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-02.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "NSUserDefaults+SQRLShipItExtensions.h"
#import "NSUserDefaults+SQRLShipItExtensionsPrivate.h"

@implementation NSUserDefaults (SQRLShipItExtensions)

// Safer than -URLForKey: because we explicitly disallow anything but file path
// URLs.
- (NSURL *)sqrl_fileURLForKey:(NSString *)key {
	NSParameterAssert(key != nil);
	return [NSURL fileURLWithPath:[self stringForKey:key]];
}

- (void)sqrl_setFileURL:(NSURL *)fileURL forKey:(NSString *)key {
	NSParameterAssert(key != nil);

	if (fileURL == nil) {
		[self removeObjectForKey:SQRLTargetBundleDefaultsKey];
	} else {
		NSString *path = fileURL.filePathURL.path;
		NSAssert(path != nil, @"URL does not point to a file path: %@", fileURL);

		[self setObject:path forKey:key];
	}
}

- (NSURL *)sqrl_targetBundleURL {
	return [self sqrl_fileURLForKey:SQRLTargetBundleDefaultsKey];
}

- (void)setSqrl_targetBundleURL:(NSURL *)fileURL {
	[self sqrl_setFileURL:fileURL forKey:SQRLTargetBundleDefaultsKey];
}

- (NSURL *)sqrl_updateBundleURL {
	return [self sqrl_fileURLForKey:SQRLUpdateBundleDefaultsKey];
}

- (void)setSqrl_updateBundleURL:(NSURL *)fileURL {
	[self sqrl_setFileURL:fileURL forKey:SQRLUpdateBundleDefaultsKey];
}

- (NSURL *)sqrl_backupBundleURL {
	return [self sqrl_fileURLForKey:SQRLBackupBundleDefaultsKey];
}

- (void)setSqrl_backupBundleURL:(NSURL *)fileURL {
	[self sqrl_setFileURL:fileURL forKey:SQRLBackupBundleDefaultsKey];
}

- (NSURL *)sqrl_applicationSupportURL {
	return [self sqrl_fileURLForKey:SQRLApplicationSupportDefaultsKey];
}

- (void)setSqrl_applicationSupportURL:(NSURL *)fileURL {
	[self sqrl_setFileURL:fileURL forKey:SQRLApplicationSupportDefaultsKey];
}

- (NSData *)sqrl_requirementData {
	return [self dataForKey:SQRLRequirementDataDefaultsKey];
}

- (void)setSqrl_requirementData:(NSData *)data {
	if (data == nil) {
		[self removeObjectForKey:SQRLRequirementDataDefaultsKey];
	} else {
		NSParameterAssert([data isKindOfClass:NSData.class]);
		[self setObject:data forKey:SQRLRequirementDataDefaultsKey];
	}
}

- (SQRLShipItState)sqrl_state {
	return [self integerForKey:SQRLStateDefaultsKey];
}

- (void)setSqrl_state:(SQRLShipItState)state {
	[self setInteger:state forKey:SQRLStateDefaultsKey];

	if (![self synchronize]) {
		NSLog(@"Failed to synchronize user defaults %@", self);
	}
}

- (NSString *)sqrl_waitForBundleIdentifier {
	return [self stringForKey:SQRLWaitForBundleIdentifierDefaultsKey];
}

- (void)setSqrl_waitForBundleIdentifier:(NSString *)identifier {
	if (identifier == nil) {
		[self removeObjectForKey:SQRLWaitForBundleIdentifierDefaultsKey];
	} else {
		NSParameterAssert([identifier isKindOfClass:NSString.class]);
		[self setObject:identifier forKey:SQRLWaitForBundleIdentifierDefaultsKey];
	}
}

- (BOOL)sqrl_relaunchAfterInstallation {
	return [self boolForKey:SQRLShouldRelaunchDefaultsKey];
}

- (void)setSqrl_relaunchAfterInstallation:(BOOL)shouldRelaunch {
	[self setBool:shouldRelaunch forKey:SQRLShouldRelaunchDefaultsKey];
}

@end
