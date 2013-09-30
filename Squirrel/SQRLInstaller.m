//
//  SQRLInstaller.m
//  Squirrel
//
//  Created by Alan Rogers on 30/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLInstaller.h"
#import "NSBundle+SQRLVersionExtensions.h"
#import "NSError+SQRLVerbosityExtensions.h"
#import "SQRLCodeSignatureVerifier.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <libkern/OSAtomic.h>
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
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

- (RACSignal *)installUpdate {
	return [[[[[[[[[self.verifier
		verifyCodeSignatureOfBundle:self.updateBundleURL]
		subscribeOn:[RACScheduler schedulerWithPriority:RACSchedulerPriorityHigh]]
		then:^{
			return [self clearQuarantineForDirectory:self.targetBundleURL];
		}]
		then:^{
			return [self verifyTargetBundleExists];
		}]
		then:^{
			return [[[self
				temporaryDirectoryAppropriateForURL:self.targetBundleURL]
				catch:^(NSError *error) {
					NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Could not create backup folder", nil)];
					return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorBackupFailed toError:error]];
				}]
				flattenMap:^(NSURL *temporaryDirectoryURL) {
					NSURL *backupBundleURL = [temporaryDirectoryURL URLByAppendingPathComponent:self.targetBundleURL.lastPathComponent];
					return [[self
						installUpdateBackingUpToURL:backupBundleURL]
						doCompleted:^{
							// This directory must be removed once we succeed, or else it ends
							// up in the user's trash directory on reboot.
							[NSFileManager.defaultManager removeItemAtURL:temporaryDirectoryURL error:NULL];
						}];
				}];
		}]
		initially:^{
			[self beginTransaction];
		}]
		finally:^{
			[self endTransaction];
		}]
		replay]
		setNameWithFormat:@"-installUpdate"];
}

- (RACSignal *)installUpdateBackingUpToURL:(NSURL *)backupBundleURL {
	NSParameterAssert(backupBundleURL != nil);

	// First, move the target out of place and into the backup location.
	return [[[[[[self
		installItemAtURL:backupBundleURL fromURL:self.targetBundleURL]
		catch:^(NSError *error) {
			NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Failed to move bundle %@ to backup location %@", nil), self.targetBundleURL, backupBundleURL];
			return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorBackupFailed toError:error]];
		}]
		then:^{
			// Move the new bundle into place.
			return [[self
				installItemAtURL:self.targetBundleURL fromURL:self.updateBundleURL]
				catch:^(NSError *error) {
					NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Failed to replace bundle %@ with update %@", nil), self.targetBundleURL, self.updateBundleURL];
					return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorReplacingTarget toError:error]];
				}];
		}]
		then:^{
			// Verify that the target bundle is valid after installation.
			return [self verifyTargetBundleCodeSignatureRecoveringUsingBackupAtURL:backupBundleURL];
		}]
		catch:^(NSError *error) {
			// Verify that the target bundle didn't get corrupted during
			// failure. Try recovering it if it did.
			return [[self
				verifyTargetBundleCodeSignatureRecoveringUsingBackupAtURL:backupBundleURL]
				then:^{
					// Recovery succeeded, but we still want to pass
					// through the original error.
					return [RACSignal error:error];
				}];
		}]
		setNameWithFormat:@"-installUpdateBackingUpToURL: %@", backupBundleURL];
}

- (RACSignal *)verifyTargetBundleExists {
	return [[RACSignal createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
		NSBundle *targetBundle = [NSBundle bundleWithURL:self.targetBundleURL];
		if (targetBundle == nil) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"URL %@ could not be opened as a bundle", nil), self.targetBundleURL],
			};

			[subscriber sendError:[NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorCouldNotOpenTarget userInfo:userInfo]];
			return nil;
		}
		
		if (targetBundle.sqrl_bundleVersion == nil) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Target bundle %@ has an invalid version", nil), self.targetBundleURL],
			};

			[subscriber sendError:[NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorInvalidBundleVersion userInfo:userInfo]];
			return nil;
		}

		[subscriber sendCompleted];
		return nil;
	}] setNameWithFormat:@"-targetBundle"];
}

- (RACSignal *)verifyTargetBundleCodeSignatureRecoveringUsingBackupAtURL:(NSURL *)backupBundleURL {
	NSParameterAssert(backupBundleURL != nil);

	return [[[[[self.verifier
		verifyCodeSignatureOfBundle:self.targetBundleURL]
		doError:^(NSError *error) {
			NSLog(@"Target bundle %@ is missing or corrupted: %@", self.targetBundleURL, error);
		}]
		catch:^(NSError *error) {
			return [[[[self
				installItemAtURL:self.targetBundleURL fromURL:backupBundleURL]
				initially:^{
					[NSFileManager.defaultManager removeItemAtURL:self.targetBundleURL error:NULL];
				}]
				doCompleted:^{
					NSLog(@"Restored backup bundle to %@", self.targetBundleURL);
				}]
				doError:^(NSError *recoveryError) {
					NSLog(@"Could not restore backup bundle %@ to %@: %@", backupBundleURL, self.targetBundleURL, recoveryError.sqrl_verboseDescription);
				}];
		}]
		replay]
		setNameWithFormat:@"-verifyTargetBundleCodeSignatureRecoveringUsingBackupAtURL: %@", backupBundleURL];
}

- (RACSignal *)installItemAtURL:(NSURL *)targetURL fromURL:(NSURL *)sourceURL {
	NSParameterAssert(targetURL != nil);
	NSParameterAssert(sourceURL != nil);

	return [[[[[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			// rename() is atomic, NSFileManager sucks.
			if (rename(sourceURL.path.fileSystemRepresentation, targetURL.path.fileSystemRepresentation) == 0) {
				[subscriber sendCompleted];
			} else {
				int code = errno;
				NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
				
				const char *desc = strerror(code);
				if (desc != NULL) userInfo[NSLocalizedDescriptionKey] = @(desc);

				[subscriber sendError:[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:userInfo]];
			}

			return nil;
		}]
		doCompleted:^{
			NSLog(@"Moved bundle from %@ to %@", sourceURL, targetURL);
		}]
		catch:^(NSError *error) {
			if (![error.domain isEqual:NSPOSIXErrorDomain] || error.code != EXDEV) return [RACSignal error:error];

			// If the locations lie on two different volumes, remove the
			// destination by hand, then perform a move.
			[NSFileManager.defaultManager removeItemAtURL:targetURL error:NULL];

			if ([NSFileManager.defaultManager moveItemAtURL:sourceURL toURL:targetURL error:&error]) {
				NSLog(@"Moved bundle across volumes from %@ to %@", sourceURL, targetURL);
				return [RACSignal empty];
			} else {
				// TODO: Wrap `error` with this message instead.
				NSLog(@"Couldn't move bundle across volumes %@", error.sqrl_verboseDescription);
				return [RACSignal error:error];
			}
		}]
		replay]
		setNameWithFormat:@"-installItemAtURL: %@ fromURL: %@", targetURL, sourceURL];
}

#pragma mark Temporary Directories

- (RACSignal *)temporaryDirectoryAppropriateForURL:(NSURL *)targetURL {
	NSParameterAssert(targetURL != nil);

	RACSignal *manualTemporaryDirectory = [RACSignal createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
		NSURL *temporaryDirectoryURL = [NSURL fileURLWithPathComponents:@[
			NSTemporaryDirectory(),
			[NSString stringWithFormat:@"com~github~ShipIt"],
			NSProcessInfo.processInfo.globallyUniqueString,
		]];

		NSError *error = nil;
		if ([NSFileManager.defaultManager createDirectoryAtURL:temporaryDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error]) {
			[subscriber sendNext:temporaryDirectoryURL];
			[subscriber sendCompleted];
		} else {
			[subscriber sendError:error];
		}

		return nil;
	}];

	return [[[[self
		temporaryDirectoryAppropriateForVolumeOfURL:targetURL]
		concat:manualTemporaryDirectory]
		take:1]
		setNameWithFormat:@"-temporaryDirectoryAppropriateForURL: %@", targetURL];
}

- (RACSignal *)temporaryDirectoryAppropriateForVolumeOfURL:(NSURL *)targetURL {
	NSParameterAssert(targetURL != nil);

	return [[[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			NSError *error = nil;
			NSURL *volumeURL = nil;
			BOOL gotVolumeURL = [targetURL getResourceValue:&volumeURL forKey:NSURLVolumeURLKey error:&error];
			if (!gotVolumeURL) {
				[subscriber sendError:error];
				return nil;
			}

			if (volumeURL != nil) [subscriber sendNext:volumeURL];
			[subscriber sendCompleted];

			return nil;
		}]
		flattenMap:^(NSURL *volumeURL) {
			NSError *error = nil;
			NSURL *temporaryDirectoryURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:volumeURL create:YES error:&error];
			if (temporaryDirectoryURL == nil) {
				return [RACSignal error:error];
			} else {
				return [RACSignal return:temporaryDirectoryURL];
			}
		}]
		setNameWithFormat:@"-temporaryDirectoryAppropriateForVolumeOfURL: %@", targetURL];
}

#pragma Quarantine Bit Removal

- (RACSignal *)clearQuarantineForDirectory:(NSURL *)directory {
	NSParameterAssert(directory != nil);

	return [[[[RACSignal
		defer:^{
			NSFileManager *manager = [[NSFileManager alloc] init];
			NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:directory includingPropertiesForKeys:nil options:0 errorHandler:^(NSURL *URL, NSError *error) {
				NSLog(@"Error enumerating item %@ within directory %@: %@", URL, directory, error);
				return YES;
			}];

			return enumerator.rac_sequence.signal;
		}]
		flattenMap:^(NSURL *URL) {
			const char *path = URL.path.fileSystemRepresentation;
			if (removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0) {
				int code = errno;

				// This code just means the extended attribute was never set on the
				// file to begin with.
				if (code != ENOATTR) {
					NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
					
					const char *desc = strerror(code);
					if (desc != NULL) userInfo[NSLocalizedDescriptionKey] = @(desc);

					return [RACSignal error:[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:userInfo]];
				}
			}

			return [RACSignal empty];
		}]
		replay]
		setNameWithFormat:@"-clearQuarantineForDirectory: %@", directory];
}

#pragma mark Error Handling

- (NSError *)errorByAddingDescription:(NSString *)description code:(NSInteger)code toError:(NSError *)error {
	NSMutableDictionary *userInfo = [error.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];

	if (description != nil) userInfo[NSLocalizedDescriptionKey] = description;
	if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

	return [NSError errorWithDomain:SQRLInstallerErrorDomain code:code userInfo:userInfo];
}

@end
