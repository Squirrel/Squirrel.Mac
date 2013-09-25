//
//  SQRLInstaller.m
//  Squirrel
//
//  Created by Alan Rogers on 30/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLInstaller.h"
#import "NSError+SQRLVerbosityExtensions.h"
#import "SQRLCodeSignatureVerifier.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <libkern/OSAtomic.h>
#import <sys/xattr.h>

NSString * const SQRLInstallerErrorDomain = @"SQRLInstallerErrorDomain";

const NSInteger SQRLInstallerErrorBackupFailed = -1;
const NSInteger SQRLInstallerErrorReplacingTarget = -2;
const NSInteger SQRLInstallerErrorCouldNotOpenTarget = -3;
const NSInteger SQRLInstallerErrorInvalidBundleVersion = -4;

// Protects access to resources that are used during the opening/closing of
// a transaction.
static NSLock *SQRLInstallerTransactionLock;

// Tracks how many concurrent transactions are in progress.
//
// This variable must only be used while `SQRLInstallerTransactionLock` is held.
static NSUInteger SQRLInstallerTransactionCount = 0;

// Prevents the machine from shutting down or sleeping while a transaction is in
// progress.
//
// This variable must only be used while `SQRLInstallerTransactionLock` is held.
static IOPMAssertionID SQRLInstallerPowerAssertion;

// How long before the `SQRLInstallerPowerAssertion` times out.
//
// This will not actually affect behavior -- it is used only for logging.
static const CFTimeInterval SQRLInstallerPowerAssertionTimeout = 10;

// Updates the behavior for handling termination signals to `func`.
//
// This function must only be called while `SQRLInstallerTransactionLock` is held.
static void SQRLInstallerReplaceSignalHandlers(sig_t func) {
	signal(SIGHUP, func);
	signal(SIGINT, func);
	signal(SIGQUIT, func);
	signal(SIGTERM, func);
}

@interface SQRLInstaller ()

@property (nonatomic, strong, readonly) NSURL *targetBundleURL;
@property (nonatomic, strong, readonly) NSURL *updateBundleURL;
@property (nonatomic, strong, readonly) SQRLCodeSignatureVerifier *verifier;

// Invoked when the installer needs to begin some uninterruptible work.
//
// A best-effort attempt will be made to protect the process from termination
// during this time.
//
// -endTransaction must be called after the work is completed. These calls can
// be nested.
- (void)beginTransaction;

// Ends a transaction previously opened with -beginTransaction.
//
// These calls may be nested, but there must be one -endTransaction call for
// each -beginTransaction call.
- (void)endTransaction;

@end

@implementation SQRLInstaller

#pragma mark Lifecycle

+ (void)initialize {
	if (self != SQRLInstaller.class) return;

	SQRLInstallerTransactionLock = [[NSLock alloc] init];
	SQRLInstallerTransactionLock.name = @"com.github.Squirrel.ShipIt.SQRLInstallerTransactionLock";
}

- (id)initWithTargetBundleURL:(NSURL *)targetBundleURL updateBundleURL:(NSURL *)updateBundleURL requirementData:(NSData *)requirementData {
	NSParameterAssert(targetBundleURL != nil);
	NSParameterAssert(updateBundleURL != nil);
	NSParameterAssert(requirementData != nil);
	
	self = [super init];
	if (self == nil) return nil;

	SecRequirementRef requirement = NULL;
	OSStatus status = SecRequirementCreateWithData((__bridge CFDataRef)requirementData, kSecCSDefaultFlags, &requirement);
	@onExit {
		if (requirement != NULL) CFRelease(requirement);
	};

	if (status != noErr) return nil;

	_verifier = [[SQRLCodeSignatureVerifier alloc] initWithRequirement:requirement];
	_targetBundleURL = targetBundleURL;
	_updateBundleURL = updateBundleURL;
	
	return self;
}

#pragma mark Transactions

- (void)beginTransaction {
	[SQRLInstallerTransactionLock lock];
	@onExit {
		[SQRLInstallerTransactionLock unlock];
	};

	// If there are any transactions already, skip initial setup.
	if (SQRLInstallerTransactionCount++ > 0) return;

	SQRLInstallerReplaceSignalHandlers(SIG_IGN);

	NSString *details = [NSString stringWithFormat:@"%@ is being updated, and interrupting the process could corrupt the application", self.targetBundleURL.path];
	IOReturn result = IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventSystemSleep, CFSTR("Updating"), (__bridge CFStringRef)details, NULL, NULL, SQRLInstallerPowerAssertionTimeout, kIOPMAssertionTimeoutActionLog, &SQRLInstallerPowerAssertion);
	if (result != kIOReturnSuccess) {
		NSLog(@"Could not install power assertion: %li", (long)result);
	}
}

- (void)endTransaction {
	[SQRLInstallerTransactionLock lock];
	@onExit {
		[SQRLInstallerTransactionLock unlock];
	};

	// If there are still transactions left, skip teardown.
	if (--SQRLInstallerTransactionCount > 0) return;

	SQRLInstallerReplaceSignalHandlers(SIG_DFL);

	IOReturn result = IOPMAssertionRelease(SQRLInstallerPowerAssertion);
	if (result != kIOReturnSuccess) {
		NSLog(@"Could not release power assertion: %li", (long)result);
	}
}

#pragma mark Installation

- (BOOL)installUpdateWithError:(NSError **)errorPtr {
	[self beginTransaction];
	@try {
		return [self reallyInstallUpdateWithError:errorPtr];
	} @finally {
		[self endTransaction];
	}
}

- (BOOL)reallyInstallUpdateWithError:(NSError **)errorPtr {
	// Verify the update bundle.
	if (![self.verifier verifyCodeSignatureOfBundle:self.updateBundleURL error:errorPtr]) {
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

	NSError *error = nil;

	// This must directory must be removed once we succeed otherwise it ends up
	// in the user's trash directory on reboot
	NSURL *temporaryDirectory = [self temporaryDirectoryAppropriateForURL:self.targetBundleURL error:&error];
	if (temporaryDirectory == nil) {
		if (errorPtr != NULL) {
			NSMutableDictionary *userInfo = [@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not create backup folder", nil)],
			} mutableCopy];

			if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

			*errorPtr = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorBackupFailed userInfo:userInfo];
		}

		return NO;
	}

	NSURL *backupBundleURL = [temporaryDirectory URLByAppendingPathComponent:self.targetBundleURL.lastPathComponent];

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
		if (![self verifyTargetURL:self.targetBundleURL error:&error]) {
			NSLog(@"Target bundle %@ is missing or corrupted: %@", self.targetBundleURL, error);
			[NSFileManager.defaultManager removeItemAtURL:self.targetBundleURL error:NULL];

			NSError *installBackupError = nil;
			if ([self installItemAtURL:self.targetBundleURL fromURL:backupBundleURL error:&installBackupError]) {
				NSLog(@"Restored backup bundle to %@", self.targetBundleURL);
				[NSFileManager.defaultManager removeItemAtURL:temporaryDirectory error:NULL];
			} else {
				NSLog(@"Could not restore backup bundle %@ to %@: %@", backupBundleURL, self.targetBundleURL, installBackupError.sqrl_verboseDescription);
				// Leave the temporary directory in place so that it's restored to trash on reboot
			}

			if (errorPtr != NULL) *errorPtr = error;
			return NO;
		}

		[NSFileManager.defaultManager removeItemAtURL:temporaryDirectory error:NULL];
	}

	return YES;
}

- (NSURL *)temporaryDirectoryAppropriateForURL:(NSURL *)targetURL error:(NSError **)errorPtr {
	NSURL *temporaryDirectory = [self temporaryDirectoryAppropriateForVolumeOfURL:targetURL];
	if (temporaryDirectory != nil) return temporaryDirectory;

	temporaryDirectory = [NSURL fileURLWithPathComponents:@[
		NSTemporaryDirectory(),
		[NSString stringWithFormat:@"com~github~ShipIt"],
		NSProcessInfo.processInfo.globallyUniqueString,
	]];
	if (![NSFileManager.defaultManager createDirectoryAtURL:temporaryDirectory withIntermediateDirectories:YES attributes:nil error:errorPtr]) return nil;

	return temporaryDirectory;
}

- (NSURL *)temporaryDirectoryAppropriateForVolumeOfURL:(NSURL *)targetURL {
	NSURL *volumeURL = nil; NSError *volumeURLError = nil;
	BOOL getVolumeURL = [targetURL getResourceValue:&volumeURL forKey:NSURLVolumeURLKey error:&volumeURLError];
	if (!getVolumeURL) return nil;

	NSError *itemReplacementDirectoryError = nil;
	NSURL *itemReplacementDirectory = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:volumeURL create:YES error:&itemReplacementDirectoryError];
	if (itemReplacementDirectory == nil) return nil;

	return itemReplacementDirectory;
}

- (BOOL)installItemAtURL:(NSURL *)targetURL fromURL:(NSURL *)sourceURL error:(NSError **)errorPtr {
	NSParameterAssert(targetURL != nil);
	NSParameterAssert(sourceURL != nil);

	// rename() is atomic, NSFileManager sucks.
	if (rename(sourceURL.path.fileSystemRepresentation, targetURL.path.fileSystemRepresentation) != 0) {
		int code = errno;
		if (code == EXDEV) {
			// If the locations lie on two different volumes, remove the
			// destination by hand, then perform a move.
			[NSFileManager.defaultManager removeItemAtURL:targetURL error:NULL];

			NSError *moveItemError = nil;
			if (![NSFileManager.defaultManager moveItemAtURL:sourceURL toURL:targetURL error:&moveItemError]) {
				NSLog(@"Couldn't move bundle across volumes %@", moveItemError.sqrl_verboseDescription);
				if (errorPtr != NULL) *errorPtr = moveItemError;
				return NO;
			}

			NSLog(@"Moved bundle across volumes from %@ to %@", sourceURL, targetURL);
			return YES;
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

- (BOOL)verifyTargetURL:(NSURL *)targetURL error:(NSError **)errorPtr {
	if (![NSFileManager.defaultManager fileExistsAtPath:targetURL.path]) {
		if (errorPtr != NULL) {
			NSDictionary *errorInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn\u2019t replace app with updated version", nil),
			};
			*errorPtr = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorReplacingTarget userInfo:errorInfo];
		}
		return NO;
	}

	return [self.verifier verifyCodeSignatureOfBundle:targetURL error:errorPtr];
}

@end
