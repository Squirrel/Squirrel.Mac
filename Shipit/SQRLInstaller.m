//
//  SQRLInstaller.m
//  Squirrel
//
//  Created by Alan Rogers on 30/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLInstaller.h"
#import "SQRLCodeSignatureVerification.h"

NSString * const SQRLInstallerErrorDomain = @"SQRLInstallerErrorDomain";

const NSInteger SQRLInstallerErrorBackupFailed = -1;
const NSInteger SQRLInstallerErrorReplacingTarget = -2;
const NSInteger SQRLInstallerErrorCouldNotOpenTarget = -3;
const NSInteger SQRLInstallerErrorInvalidBundleVersion = -4;

@interface SQRLInstaller ()

@property (nonatomic, strong, readonly) NSURL *targetBundleURL;
@property (nonatomic, strong, readonly) NSURL *updateBundleURL;
@property (nonatomic, strong, readonly) NSURL *backupURL;

@end

@implementation SQRLInstaller

#pragma mark Lifecycle

- (id)initWithTargetBundleURL:(NSURL *)targetBundleURL updateBundleURL:(NSURL *)updateBundleURL backupURL:(NSURL *)backupURL {
	NSParameterAssert(targetBundleURL != nil);
	NSParameterAssert(updateBundleURL != nil);
	NSParameterAssert(backupURL != nil);
	
	self = [super init];
	if (self == nil) return nil;
	
	_targetBundleURL = targetBundleURL;
	_updateBundleURL = updateBundleURL;
	_backupURL = backupURL;
	
	return self;
}

#pragma mark Installation

- (BOOL)installUpdateWithError:(NSError **)errorPtr {
	// Verify the update bundle.
	if (![SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:self.updateBundleURL error:errorPtr]) {
		return NO;
	}
	
	// Move the old bundle to a backup location
	NSBundle *targetBundle = [NSBundle bundleWithURL:self.targetBundleURL];
	if (targetBundle == nil) {
		if (errorPtr != NULL) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"URL %@ could not be opened as a bundle", nil), self.targetBundleURL],
			};

			*errorPtr = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorCouldNotOpenTarget userInfo:userInfo];
		}

		return NO;
	}

	NSString *bundleVersion = [targetBundle objectForInfoDictionaryKey:(id)kCFBundleVersionKey];
	if (bundleVersion == nil) {
		if (errorPtr != NULL) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Target bundle %@ has an invalid version", nil), self.targetBundleURL],
			};

			*errorPtr = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorInvalidBundleVersion userInfo:userInfo];
		}

		return NO;
	}

	NSString *bundleExtension = self.targetBundleURL.pathExtension;
	NSString *backupAppName = [NSString stringWithFormat:@"%@_%@.%@", self.targetBundleURL.URLByDeletingPathExtension.lastPathComponent, bundleVersion, bundleExtension];

	// FIXME: We should just use a temporary URL (or at least filename) for
	// backups. It's silly that updating will fail if something's here that we
	// can't remove.
	NSURL *backupBundleURL = [self.backupURL URLByAppendingPathComponent:backupAppName];
	NSAssert(backupBundleURL != nil, @"nil backupBundleURL after appending \"%@\" to URL %@", backupAppName, self.backupURL);
	
	NSError *error = nil;
	if (![self installItemAtURL:backupBundleURL fromURL:self.targetBundleURL error:&error]) {
		if (errorPtr != NULL) {
			NSMutableDictionary *userInfo = [@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Failed to copy bundle %@ to backup location %@", nil), self.targetBundleURL, backupBundleURL],
			} mutableCopy];

			if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

			*errorPtr = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorBackupFailed userInfo:userInfo];
		}

		return NO;
	}
	
	// Move the new bundle into place.
	if (![self installItemAtURL:self.targetBundleURL fromURL:self.updateBundleURL error:&error]) {
		if (errorPtr != NULL) {
			NSMutableDictionary *userInfo = [@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Failed to replace bundle %@ with update %@", nil), self.targetBundleURL, self.updateBundleURL],
			} mutableCopy];

			if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

			*errorPtr = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorReplacingTarget userInfo:userInfo];
		}

		return NO;
	}
	
	// Verify the bundle in place
	if (![SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:self.targetBundleURL error:errorPtr]) {
		// Move the backup version back into place
		if (![self installItemAtURL:self.targetBundleURL fromURL:backupBundleURL error:&error]) {
			NSLog(@"Could not move backup bundle %@ back to %@ after codesign failure: %@", backupBundleURL, self.targetBundleURL, error);
		}

		return NO;
	}
	
	return YES;
}

- (BOOL)installItemAtURL:(NSURL *)targetURL fromURL:(NSURL *)sourceURL error:(NSError **)errorPtr {
	NSParameterAssert(targetURL != nil);
	NSParameterAssert(sourceURL != nil);

	// rename() is atomic and makes sure to remove the destination,
	// whereas NSFileManager sucks.
	if (rename(sourceURL.path.fileSystemRepresentation, targetURL.path.fileSystemRepresentation) != 0) {
		if (errorPtr != NULL) {
			NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
			
			int code = errno;
			const char *desc = strerror(code);
			if (desc != NULL) userInfo[NSLocalizedDescriptionKey] = @(desc);

			*errorPtr = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:userInfo];
		}

		return NO;
	}

	NSLog(@"Moved bundle from %@ to %@", sourceURL, targetURL);
	return YES;
}

@end
