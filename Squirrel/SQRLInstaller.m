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
#import "SQRLStateManager.h"
#import "SQRLTerminationListener.h"
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
const NSInteger SQRLInstallerErrorMissingInstallationData = -5;
const NSInteger SQRLInstallerErrorInvalidState = -6;
const NSInteger SQRLInstallerErrorMovingAcrossVolumes = -7;

// How long before the `SQRLInstallerPowerAssertion` times out.
//
// This will not actually affect behavior -- it is used only for logging.
static const CFTimeInterval SQRLInstallerPowerAssertionTimeout = 10;

@interface SQRLInstaller ()

// The state manager to read and write from.
@property (nonatomic, strong, readonly) SQRLStateManager *stateManager;

// Tracks how many concurrent transactions are in progress.
//
// This property must only be used while synchronized on the receiver.
@property (nonatomic, assign) NSUInteger transactionCount;

// Prevents the machine from shutting down or sleeping while a transaction is in
// progress.
//
// This property must only be used while synchronized on the receiver.
@property (nonatomic, assign) IOPMAssertionID powerAssertion;

// Updates the behavior for handling termination signals.
//
// func - The new handler for termination signals.
//
// This function must only be called while synchronized on the receiver.
- (void)replaceSignalHandlers:(sig_t)func;

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

- (id)initWithStateManager:(SQRLStateManager *)stateManager {
	NSParameterAssert(stateManager != nil);

	self = [super init];
	if (self == nil) return nil;

	_stateManager = stateManager;

	@weakify(self);
	_installUpdateCommand = [[RACCommand alloc] initWithSignalBlock:^(id _) {
		@strongify(self);
		return [[[self
			signalForCurrentState]
			initially:^{
				[self beginTransaction];
			}]
			finally:^{
				[self endTransaction];
			}];
	}];
	
	return self;
}

#pragma mark Transactions

- (void)beginTransaction {
	@synchronized (self) {
		// If there are any transactions already, skip initial setup.
		if (self.transactionCount++ > 0) return;

		[self replaceSignalHandlers:SIG_IGN];

		NSString *details = [NSString stringWithFormat:@"%@ is being updated, and interrupting the process could corrupt the application", self.stateManager.targetBundleURL.path];

		IOPMAssertionID assertion;
		IOReturn result = IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventSystemSleep, CFSTR("Updating"), (__bridge CFStringRef)details, NULL, NULL, SQRLInstallerPowerAssertionTimeout, kIOPMAssertionTimeoutActionLog, &assertion);
		if (result == kIOReturnSuccess) {
			self.powerAssertion = assertion;
		} else {
			NSLog(@"Could not install power assertion: %li", (long)result);
		}
	}
}

- (void)endTransaction {
	@synchronized (self) {
		// If there are still transactions left, skip teardown.
		if (--self.transactionCount > 0) return;

		[self replaceSignalHandlers:SIG_DFL];

		IOReturn result = IOPMAssertionRelease(self.powerAssertion);
		if (result != kIOReturnSuccess) {
			NSLog(@"Could not release power assertion: %li", (long)result);
		}
	}
}

- (void)replaceSignalHandlers:(sig_t)func {
	signal(SIGHUP, func);
	signal(SIGINT, func);
	signal(SIGQUIT, func);
	signal(SIGTERM, func);
}

#pragma mark Installer State

- (RACSignal *)retrieveDefaultsValueWithDescription:(NSString *)description block:(id (^)(void))block {
	NSParameterAssert(description != nil);
	NSParameterAssert(block != nil);

	return [[RACSignal
		defer:^{
			id value = block();
			if (value == nil) {
				NSString *errorDescription = [NSString stringWithFormat:NSLocalizedString(@"Missing %@", nil), description];
				return [RACSignal error:[self missingDataErrorWithDescription:errorDescription]];
			} else {
				return [RACSignal return:value];
			}
		}]
		setNameWithFormat:@"-retrieveDefaultsValueWithDescription: %@ block:", description];
}

- (RACSignal *)targetBundleURL {
	return [self retrieveDefaultsValueWithDescription:@"target bundle URL" block:^{
		return self.stateManager.targetBundleURL;
	}];
}

- (RACSignal *)backupBundleURL {
	return [self retrieveDefaultsValueWithDescription:@"backup bundle URL" block:^{
		return self.stateManager.backupBundleURL;
	}];
}

- (RACSignal *)updateBundleURL {
	return [self retrieveDefaultsValueWithDescription:@"update bundle URL" block:^{
		return self.stateManager.updateBundleURL;
	}];
}

- (RACSignal *)applicationSupportURL {
	return [self retrieveDefaultsValueWithDescription:@"Application Support URL" block:^{
		return self.stateManager.applicationSupportURL;
	}];
}

- (RACSignal *)relaunchAfterInstallation {
	return [[RACSignal
		defer:^{
			return [RACSignal return:@(self.stateManager.relaunchAfterInstallation)];
		}]
		setNameWithFormat:@"-relaunchAfterInstallation"];
}

- (RACSignal *)verifier {
	return [[[self
		retrieveDefaultsValueWithDescription:@"code signing requirement" block:^{
			return self.stateManager.requirementData;
		}]
		flattenMap:^(NSData *requirementData) {
			SecRequirementRef requirement = NULL;
			OSStatus status = SecRequirementCreateWithData((__bridge CFDataRef)requirementData, kSecCSDefaultFlags, &requirement);
			@onExit {
				if (requirement != NULL) CFRelease(requirement);
			};

			if (status == noErr) {
				return [RACSignal return:[[SQRLCodeSignatureVerifier alloc] initWithRequirement:requirement]];
			} else {
				return [RACSignal error:[NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil]];
			}
		}]
		setNameWithFormat:@"-verifier"];
}

- (RACSignal *)signalForCurrentState {
	SQRLShipItState state = self.stateManager.state;
	if (state == SQRLShipItStateNothingToDo) return [RACSignal empty];

	return [[[[self
		signalForState:state]
		doCompleted:^{
			NSLog(@"Completed state %i", (int)state);
		}]
		concat:[RACSignal defer:^{
			return [self signalForCurrentState];
		}]]
		setNameWithFormat:@"-signalForCurrentState"];
}

- (RACSignal *)signalForState:(SQRLShipItState)state {
	// This case is covered in -signalForCurrentState.
	NSParameterAssert(state != SQRLShipItStateNothingToDo);

	switch (state) {
		case SQRLShipItStateClearingQuarantine:
			return [[[[[self
				updateBundleURL]
				flattenMap:^(NSURL *bundleURL) {
					return [self clearQuarantineForDirectory:bundleURL];
				}]
				doCompleted:^{
					self.stateManager.state = SQRLShipItStateBackingUp;
				}]
				ignoreValues]
				setNameWithFormat:@"SQRLShipItStateClearingQuarantine"];

		case SQRLShipItStateBackingUp:
			return [[[[[[RACSignal
				zip:@[
					[self targetBundleURL],
					[self applicationSupportURL],
					[[self backupBundleURL] catchTo:[RACSignal return:nil]],
					[self verifier],
				] reduce:^(NSURL *bundleURL, NSURL *appSupportURL, NSURL *backupBundleURL, SQRLCodeSignatureVerifier *verifier) {
					RACSignal *skipBackup = [RACSignal return:@NO];
					if (backupBundleURL != nil) {
						skipBackup = [self checkWhetherItemPreviouslyAtURL:bundleURL wasInstalledAtURL:backupBundleURL usingVerifier:verifier];
					}

					return [skipBackup flattenMap:^(NSNumber *skip) {
						if (skip.boolValue) {
							return [RACSignal empty];
						} else {
							return [self moveBundleAtURL:bundleURL intoBackupDirectoryAtURL:appSupportURL];
						}
					}];
				}]
				flatten]
				doNext:^(NSURL *backupBundleURL) {
					// Save the chosen backup URL as soon as we have it, so we
					// can resume even if the state change hasn't taken effect.
					self.stateManager.backupBundleURL = backupBundleURL;
					[self.stateManager synchronize];
				}]
				doCompleted:^{
					self.stateManager.state = SQRLShipItStateInstalling;
				}]
				ignoreValues]
				setNameWithFormat:@"SQRLShipItStateBackingUp"];

		case SQRLShipItStateInstalling:
			return [[[[[RACSignal
				zip:@[
					[self targetBundleURL],
					[self updateBundleURL],
					[self backupBundleURL],
					[self verifier]
				] reduce:^(NSURL *targetBundleURL, NSURL *updateBundleURL, NSURL *backupBundleURL, SQRLCodeSignatureVerifier *verifier) {
					return [[[[self
						checkWhetherItemPreviouslyAtURL:updateBundleURL wasInstalledAtURL:targetBundleURL usingVerifier:verifier]
						flattenMap:^(NSNumber *skip) {
							if (skip.boolValue) {
								return [RACSignal empty];
							} else {
								return [self installItemAtURL:targetBundleURL fromURL:updateBundleURL];
							}
						}]
						catch:^(NSError *error) {
							NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Failed to replace bundle %@ with update %@", nil), targetBundleURL, updateBundleURL];
							return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorReplacingTarget toError:error]];
						}]
						catch:^(NSError *error) {
							// Verify that the target bundle didn't get corrupted during
							// failure. Try recovering it if it did.
							return [[self
								verifyCodeSignatureOfBundleAtURL:targetBundleURL usingVerifier:verifier recoveringUsingBackupAtURL:backupBundleURL]
								then:^{
									// Recovery succeeded, but we still want to pass
									// through the original error.
									return [RACSignal error:error];
								}];
						}];
				}]
				flatten]
				doCompleted:^{
					self.stateManager.state = SQRLShipItStateVerifyingInPlace;
				}]
				ignoreValues]
				setNameWithFormat:@"SQRLShipItStateInstalling"];

		case SQRLShipItStateVerifyingInPlace:
			return [[[[[RACSignal
				zip:@[
					[self targetBundleURL],
					[self backupBundleURL],
					[self verifier]
				] reduce:^(NSURL *targetBundleURL, NSURL *backupBundleURL, SQRLCodeSignatureVerifier *verifier) {
					return [[self
						verifyCodeSignatureOfBundleAtURL:targetBundleURL usingVerifier:verifier recoveringUsingBackupAtURL:backupBundleURL]
						then:^{
							return [[self
								deleteBackupAtURL:backupBundleURL]
								catchTo:[RACSignal empty]];
						}];
				}]
				flatten]
				doCompleted:^{
					self.stateManager.state = SQRLShipItStateRelaunching;
				}]
				ignoreValues]
				setNameWithFormat:@"SQRLShipItStateVerifyingInPlace"];

		case SQRLShipItStateRelaunching:
			return [[[[[[[self
				relaunchAfterInstallation]
				flattenMap:^(NSNumber *shouldRelaunch) {
					if (shouldRelaunch.boolValue) {
						return [self targetBundleURL];
					} else {
						return [RACSignal empty];
					}
				}]
				deliverOn:RACScheduler.mainThreadScheduler]
				flattenMap:^(NSURL *bundleURL) {
					NSError *error = nil;
					if ([NSWorkspace.sharedWorkspace launchApplicationAtURL:bundleURL options:NSWorkspaceLaunchDefault configuration:nil error:&error]) {
						return [RACSignal empty];
					} else {
						return [RACSignal error:error];
					}
				}]
				doCompleted:^{
					self.stateManager.state = SQRLShipItStateNothingToDo;
				}]
				ignoreValues]
				setNameWithFormat:@"SQRLShipItStateRelaunching"];
		
		default: {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Invalid installer state", nil),
				NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Try installing the update again.", nil)
			};

			return [RACSignal error:[NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorInvalidState userInfo:userInfo]];
		}
	}
}

#pragma mark Backing Up

- (RACSignal *)moveBundleAtURL:(NSURL *)targetBundleURL intoBackupDirectoryAtURL:(NSURL *)parentDirectoryURL {
	NSParameterAssert(targetBundleURL != nil);
	NSParameterAssert(parentDirectoryURL != nil);

	return [[[[[RACSignal
		defer:^{
			NSError *error = nil;
			NSURL *temporaryDirectoryURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:parentDirectoryURL create:YES error:&error];
			if (temporaryDirectoryURL == nil) {
				return [RACSignal error:error];
			} else {
				return [RACSignal return:temporaryDirectoryURL];
			}
		}]
		catch:^(NSError *error) {
			NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Could not create backup folder", nil)];
			return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorBackupFailed toError:error]];
		}]
		map:^(NSURL *temporaryDirectoryURL) {
			return [temporaryDirectoryURL URLByAppendingPathComponent:targetBundleURL.lastPathComponent];
		}]
		flattenMap:^(NSURL *backupBundleURL) {
			return [[[[self
				installItemAtURL:backupBundleURL fromURL:targetBundleURL]
				catch:^(NSError *error) {
					NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Failed to move bundle %@ to backup location %@", nil), targetBundleURL, backupBundleURL];
					return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorBackupFailed toError:error]];
				}]
				ignoreValues]
				// Return the backup URL before doing any work, to increase
				// fault tolerance.
				startWith:backupBundleURL];
		}]
		setNameWithFormat:@"-moveBundleAtURL: %@ intoBackupDirectoryAtURL: %@", targetBundleURL, parentDirectoryURL];
}

- (RACSignal *)deleteBackupAtURL:(NSURL *)backupURL {
	NSParameterAssert(backupURL != nil);

	return [[[RACSignal
		defer:^{
			NSError *error = nil;
			if ([NSFileManager.defaultManager removeItemAtURL:backupURL error:&error]) {
				return [RACSignal empty];
			} else {
				return [RACSignal error:error];
			}
		}]
		then:^{
			// Also remove the temporary directory that the backup lived in.
			NSURL *temporaryDirectoryURL = backupURL.URLByDeletingLastPathComponent;

			// However, use rmdir() to skip it in case there are other files
			// contained within (for whatever reason).
			if (rmdir(temporaryDirectoryURL.path.fileSystemRepresentation) == 0) {
				return [RACSignal empty];
			} else {
				return [RACSignal error:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]];
			}
		}]
		setNameWithFormat:@"-deleteBackupAtURL: %@", backupURL];
}

- (RACSignal *)verifyCodeSignatureOfBundleAtURL:(NSURL *)bundleURL usingVerifier:(SQRLCodeSignatureVerifier *)verifier recoveringUsingBackupAtURL:(NSURL *)backupBundleURL {
	NSParameterAssert(bundleURL != nil);
	NSParameterAssert(verifier != nil);

	return [[[[verifier
		verifyCodeSignatureOfBundle:bundleURL]
		doError:^(NSError *error) {
			NSLog(@"Bundle %@ is missing or corrupted: %@", bundleURL, error);
		}]
		catch:^(NSError *error) {
			if (backupBundleURL == nil) return [RACSignal error:error];

			return [[[[self
				installItemAtURL:bundleURL fromURL:backupBundleURL]
				initially:^{
					[NSFileManager.defaultManager removeItemAtURL:bundleURL error:NULL];
				}]
				doCompleted:^{
					NSLog(@"Restored backup bundle to %@", bundleURL);
				}]
				doError:^(NSError *recoveryError) {
					NSLog(@"Could not restore backup bundle %@ to %@: %@", backupBundleURL, bundleURL, recoveryError.sqrl_verboseDescription);
				}];
		}]
		setNameWithFormat:@"-verifyCodeSignatureOfBundleAtURL: %@ usingVerifier: %@ recoveringUsingBackupAtURL: %@", bundleURL, verifier, backupBundleURL];
}

#pragma mark Installation

- (RACSignal *)checkWhetherItemPreviouslyAtURL:(NSURL *)sourceURL wasInstalledAtURL:(NSURL *)targetURL usingVerifier:(SQRLCodeSignatureVerifier *)verifier {
	NSParameterAssert(targetURL != nil);
	NSParameterAssert(sourceURL != nil);
	NSParameterAssert(verifier != nil);

	return [[[[self
		verifyCodeSignatureOfBundleAtURL:targetURL usingVerifier:verifier recoveringUsingBackupAtURL:nil]
		then:^{
			return [RACSignal return:@YES];
		}]
		catch:^(NSError *error) {
			BOOL directory;
			if ([NSFileManager.defaultManager fileExistsAtPath:sourceURL.path isDirectory:&directory]) {
				// If the source still exists, this isn't an error.
				return [RACSignal return:@NO];
			} else {
				return [RACSignal error:error];
			}
		}]
		setNameWithFormat:@"-checkWhetherItemPreviouslyAtURL: %@ wasInstalledAtURL: %@", sourceURL, targetURL];
}

- (RACSignal *)installItemAtURL:(NSURL *)targetURL fromURL:(NSURL *)sourceURL {
	NSParameterAssert(targetURL != nil);
	NSParameterAssert(sourceURL != nil);

	return [[[[RACSignal
		defer:^{
			// rename() is atomic, NSFileManager sucks.
			if (rename(sourceURL.path.fileSystemRepresentation, targetURL.path.fileSystemRepresentation) == 0) {
				return [RACSignal empty];
			} else {
				int code = errno;
				NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
				
				const char *desc = strerror(code);
				if (desc != NULL) userInfo[NSLocalizedDescriptionKey] = @(desc);

				return [RACSignal error:[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:userInfo]];
			}
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
				NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Couldn't move bundle %@ across volumes to %@", nil), sourceURL, targetURL];
				return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorMovingAcrossVolumes toError:error]];
			}
		}]
		setNameWithFormat:@"-installItemAtURL: %@ fromURL: %@", targetURL, sourceURL];
}

#pragma Quarantine Bit Removal

- (RACSignal *)clearQuarantineForDirectory:(NSURL *)directory {
	NSParameterAssert(directory != nil);

	return [[[RACSignal
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
		setNameWithFormat:@"-clearQuarantineForDirectory: %@", directory];
}

#pragma mark Error Handling

- (NSError *)missingDataErrorWithDescription:(NSString *)description {
	NSParameterAssert(description != nil);

	NSDictionary *userInfo = @{
		NSLocalizedDescriptionKey: description,
		NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Try installing the update again.", nil)
	};

	return [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorMissingInstallationData userInfo:userInfo];
}

- (NSError *)errorByAddingDescription:(NSString *)description code:(NSInteger)code toError:(NSError *)error {
	NSMutableDictionary *userInfo = [error.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];

	if (description != nil) userInfo[NSLocalizedDescriptionKey] = description;
	if (error != nil) userInfo[NSUnderlyingErrorKey] = error;

	return [NSError errorWithDomain:SQRLInstallerErrorDomain code:code userInfo:userInfo];
}

@end
