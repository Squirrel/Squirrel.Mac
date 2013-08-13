//
//  SQRLInstaller.m
//  Squirrel
//
//  Created by Alan Rogers on 30/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLInstaller.h"
#import "NSError+SQRLVerbosityExtensions.h"
#import "SQRLCodeSignatureVerification.h"
#import <libkern/OSAtomic.h>
#import <sys/xattr.h>

NSString * const SQRLInstallerErrorDomain = @"SQRLInstallerErrorDomain";

const NSInteger SQRLInstallerErrorBackupFailed = -1;
const NSInteger SQRLInstallerErrorReplacingTarget = -2;
const NSInteger SQRLInstallerErrorCouldNotOpenTarget = -3;
const NSInteger SQRLInstallerErrorInvalidBundleVersion = -4;

// Protects access to SQRLReplaceSignalHandlers and
// SQRLInstallerTransactionCount.
static NSLock *SQRLSignalHandlersLock;

// Tracks how many concurrent installations are in progress.
//
// This is used to control how ShipIt handles signals.
static NSUInteger SQRLInstallerTransactionCount = 0;

// Updates the behavior for handling termination signals.
static void SQRLReplaceSignalHandlers(sig_t func) {
	signal(SIGHUP, func);
	signal(SIGINT, func);
	signal(SIGQUIT, func);
	signal(SIGTERM, func);
}

@interface SQRLInstaller ()

@property (nonatomic, strong, readonly) NSURL *targetBundleURL;
@property (nonatomic, strong, readonly) NSURL *updateBundleURL;
@property (nonatomic, strong, readonly) NSURL *backupURL;

@end

@implementation SQRLInstaller

#pragma mark Lifecycle

+ (void)initialize {
	if (self != SQRLInstaller.class) return;

	SQRLSignalHandlersLock = [[NSLock alloc] init];
	SQRLSignalHandlersLock.name = @"com.github.Squirrel.ShipIt.SQRLSignalHandlersLock";
}

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

- (void)enableSignalCatching {
	[SQRLSignalHandlersLock lock];
	@onExit {
		[SQRLSignalHandlersLock unlock];
	};

	if (SQRLInstallerTransactionCount++ == 0) {
		// This is the first transaction, install handlers.
		SQRLReplaceSignalHandlers(SIG_IGN);
	}
}

- (void)disableSignalCatching {
	[SQRLSignalHandlersLock lock];
	@onExit {
		[SQRLSignalHandlersLock unlock];
	};

	if (--SQRLInstallerTransactionCount == 0) {
		// This is the last transaction, remove handlers.
		SQRLReplaceSignalHandlers(SIG_DFL);
	}
}

- (BOOL)installUpdateWithError:(NSError **)errorPtr {
	[self enableSignalCatching];
	@onExit {
		[self disableSignalCatching];
	};

	// Verify the update bundle.
	if (![SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:self.updateBundleURL error:errorPtr]) {
		return NO;
	}

	// Clear the quarantine bit on the update.
	if (![self clearQuarantineForDirectory:self.targetBundleURL error:errorPtr]) {
		return NO;
	}
	
	// Create a backup location for the original bundle.
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

	// This will actually create the directory no matter what we do, but it's
	// okay. We'll just overwrite it in the next step.
	NSError *error = nil;
	NSURL *backupBundleURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:self.backupURL create:NO error:&error];
	if (backupBundleURL == nil) {
		if (errorPtr != NULL) {
			NSMutableDictionary *userInfo = [@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not create temporary backup folder in %@", nil), self.backupURL],
			} mutableCopy];

			if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

			*errorPtr = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorBackupFailed userInfo:userInfo];
		}

		return NO;
	}

	@try {
		// First, move the target out of place and into the backup location.
		if (![self installItemAtURL:backupBundleURL fromURL:self.targetBundleURL error:&error]) {
			if (errorPtr != NULL) {
				NSMutableDictionary *userInfo = [@{
					NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Failed to move bundle %@ to backup location %@", nil), self.targetBundleURL, backupBundleURL],
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
	} @finally {
		NSError *error = nil;
		if (![NSFileManager.defaultManager fileExistsAtPath:self.targetBundleURL.path] || ![SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:self.targetBundleURL error:&error]) {
			NSLog(@"Target bundle %@ is missing or corrupted: %@", self.targetBundleURL, error);
			[NSFileManager.defaultManager removeItemAtURL:self.targetBundleURL error:NULL];

			if ([self installItemAtURL:self.targetBundleURL fromURL:backupBundleURL error:&error]) {
				[NSFileManager.defaultManager removeItemAtURL:backupBundleURL error:NULL];
			} else {
				NSLog(@"Could not restore backup bundle %@ to %@: %@", backupBundleURL, self.targetBundleURL, error.sqrl_verboseDescription);
			}
		}
	}

	return YES;
}

- (BOOL)installItemAtURL:(NSURL *)targetURL fromURL:(NSURL *)sourceURL error:(NSError **)errorPtr {
	NSParameterAssert(targetURL != nil);
	NSParameterAssert(sourceURL != nil);

	// rename() is atomic and makes sure to remove the destination,
	// whereas NSFileManager sucks.
	if (rename(sourceURL.path.fileSystemRepresentation, targetURL.path.fileSystemRepresentation) != 0) {
		int code = errno;
		if (code == EXDEV) {
			// If the locations lie on two different volumes, remove the
			// destination by hand, then perform a move.
			[NSFileManager.defaultManager removeItemAtURL:targetURL error:NULL];

			if ([NSFileManager.defaultManager moveItemAtURL:sourceURL toURL:targetURL error:errorPtr]) {
				NSLog(@"Moved bundle across volumes from %@ to %@", sourceURL, targetURL);
				return YES;
			} else {
				return NO;
			}
		}

		if (errorPtr != NULL) {
			NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
			
			const char *desc = strerror(code);
			if (desc != NULL) userInfo[NSLocalizedDescriptionKey] = @(desc);

			*errorPtr = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:userInfo];
		}

		return NO;
	}

	NSLog(@"Moved bundle from %@ to %@", sourceURL, targetURL);
	return YES;
}

- (BOOL)clearQuarantineForDirectory:(NSURL *)directory error:(NSError **)error {
	NSParameterAssert(directory != nil);

	NSFileManager *manager = [[NSFileManager alloc] init];
	NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:directory includingPropertiesForKeys:nil options:0 errorHandler:^(NSURL *URL, NSError *error) {
		NSLog(@"Error enumerating item %@ within directory %@: %@", URL, directory, error);
		return YES;
	}];

	for (NSURL *URL in enumerator) {
		const char *path = URL.path.fileSystemRepresentation;
		if (removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0) {
			int code = errno;
			if (code == ENOATTR) {
				// This just means the extended attribute was never set on the
				// file to begin with.
				continue;
			}

			if (error != NULL) {
				NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
				
				const char *desc = strerror(code);
				if (desc != NULL) userInfo[NSLocalizedDescriptionKey] = @(desc);

				*error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:userInfo];
			}

			return NO;
		}
	}

	return YES;
}

@end
