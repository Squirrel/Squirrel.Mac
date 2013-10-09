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
#import "RACSignal+SQRLTransactionExtensions.h"
#import "SQRLCodeSignature.h"
#import "SQRLDirectoryManager.h"
#import "SQRLShipItState.h"
#import "SQRLTerminationListener.h"
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

// Finds the state file to read and write from.
@property (nonatomic, strong, readonly) SQRLDirectoryManager *directoryManager;

@end

@implementation SQRLInstaller

#pragma mark Lifecycle

- (id)initWithDirectoryManager:(SQRLDirectoryManager *)directoryManager {
	NSParameterAssert(directoryManager != nil);

	self = [super init];
	if (self == nil) return nil;

	_directoryManager = directoryManager;

	@weakify(self);

	RACSignal *aborting = [[[[RACObserve(self, abortInstallationCommand)
		ignore:nil]
		map:^(RACCommand *command) {
			return command.executing;
		}]
		switchToLatest]
		setNameWithFormat:@"aborting"];

	_installUpdateCommand = [[RACCommand alloc] initWithEnabled:[aborting not] signalBlock:^(SQRLShipItState *state) {
		@strongify(self);
		NSParameterAssert(state != nil);

		return [[self
			installUsingState:state]
			sqrl_addTransactionWithName:NSLocalizedString(@"Updating", nil) description:NSLocalizedString(@"%@ is being updated, and interrupting the process could corrupt the application", nil), state.targetBundleURL.path];
	}];

	_abortInstallationCommand = [[RACCommand alloc] initWithEnabled:[self.installUpdateCommand.executing not] signalBlock:^(SQRLShipItState *state) {
		@strongify(self);
		NSParameterAssert(state != nil);

		return [[[RACSignal
			zip:@[
				[self ensure:@keypath(state.targetBundleURL) fromState:state],
				[self ensure:@keypath(state.codeSignature) fromState:state]
			] reduce:^(NSURL *targetBundleURL, SQRLCodeSignature *codeSignature) {
				return [self verifyBundleAtURL:targetBundleURL usingSignature:codeSignature recoveringUsingBackupAtURL:state.backupBundleURL];
			}]
			flatten]
			sqrl_addTransactionWithName:NSLocalizedString(@"Aborting update", nil) description:NSLocalizedString(@"An update to %@ is being rolled back, and interrupting the process could corrupt the application", nil), state.targetBundleURL.path];
	}];
	
	return self;
}

#pragma mark Installer State

- (RACSignal *)ensure:(NSString *)key fromState:(SQRLShipItState *)state {
	NSParameterAssert(key != nil);
	NSParameterAssert(state != nil);

	return [[RACSignal
		defer:^{
			id value = [state valueForKey:key];
			if (value == nil) {
				NSString *errorDescription = [NSString stringWithFormat:NSLocalizedString(@"Missing %@", nil), key];
				return [RACSignal error:[self missingDataErrorWithDescription:errorDescription]];
			} else {
				return [RACSignal return:value];
			}
		}]
		setNameWithFormat:@"%@ -ensure: %@ fromState: %@", self, key, state];
}

- (RACSignal *)installUsingState:(SQRLShipItState *)state {
	NSParameterAssert(state != nil);

	SQRLInstallerState installerState = state.installerState;
	if (installerState == SQRLInstallerStateNothingToDo) return [RACSignal empty];

	return [[[[self
		signalForState:state]
		doCompleted:^{
			NSLog(@"Completed step %i", (int)installerState);
		}]
		concat:[RACSignal defer:^{
			return [self installUsingState:state];
		}]]
		setNameWithFormat:@"%@ -installUsingState: %@", self, state];
}

- (RACSignal *)signalForState:(SQRLShipItState *)state {
	NSParameterAssert(state != nil);

	// This case is covered in -installUsingState:.
	NSParameterAssert(state.installerState != SQRLInstallerStateNothingToDo);

	switch (state.installerState) {
		case SQRLInstallerStateClearingQuarantine:
			return [[[[self
				ensure:@keypath(state.updateBundleURL) fromState:state]
				flattenMap:^(NSURL *bundleURL) {
					return [self clearQuarantineForDirectory:bundleURL];
				}]
				then:^{
					state.installerState = SQRLInstallerStateBackingUp;
					state.installationStateAttempt = 1;
					return [state writeUsingDirectoryManager:self.directoryManager];
				}]
				setNameWithFormat:@"SQRLInstallerStateClearingQuarantine"];

		case SQRLInstallerStateBackingUp:
			return [[[[[RACSignal
				zip:@[
					[self ensure:@keypath(state.targetBundleURL) fromState:state],
					[self ensure:@keypath(state.codeSignature) fromState:state],
				] reduce:^(NSURL *bundleURL, SQRLCodeSignature *codeSignature) {
					RACSignal *skipBackup = [RACSignal return:@NO];
					if (state.backupBundleURL != nil) {
						skipBackup = [self checkWhetherItemPreviouslyAtURL:bundleURL wasInstalledAtURL:state.backupBundleURL usingSignature:codeSignature];
					}

					return [skipBackup flattenMap:^(NSNumber *skip) {
						if (skip.boolValue) {
							return [RACSignal empty];
						} else {
							return [self backUpBundleAtURL:bundleURL];
						}
					}];
				}]
				flatten]
				flattenMap:^(NSURL *backupBundleURL) {
					// Save the chosen backup URL as soon as we have it, so we
					// can resume even if the state change hasn't taken effect.
					state.backupBundleURL = backupBundleURL;
					return [state writeUsingDirectoryManager:self.directoryManager];
				}]
				then:^{
					state.installerState = SQRLInstallerStateInstalling;
					state.installationStateAttempt = 1;
					return [state writeUsingDirectoryManager:self.directoryManager];
				}]
				setNameWithFormat:@"SQRLInstallerStateBackingUp"];

		case SQRLInstallerStateInstalling:
			return [[[[RACSignal
				zip:@[
					[self ensure:@keypath(state.targetBundleURL) fromState:state],
					[self ensure:@keypath(state.updateBundleURL) fromState:state],
					[self ensure:@keypath(state.backupBundleURL) fromState:state],
					[self ensure:@keypath(state.codeSignature) fromState:state]
				] reduce:^(NSURL *targetBundleURL, NSURL *updateBundleURL, NSURL *backupBundleURL, SQRLCodeSignature *codeSignature) {
					return [[[[self
						checkWhetherItemPreviouslyAtURL:updateBundleURL wasInstalledAtURL:targetBundleURL usingSignature:codeSignature]
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
								verifyBundleAtURL:targetBundleURL usingSignature:codeSignature recoveringUsingBackupAtURL:backupBundleURL]
								then:^{
									// Recovery succeeded, but we still want to pass
									// through the original error.
									return [RACSignal error:error];
								}];
						}];
				}]
				flatten]
				then:^{
					state.installerState = SQRLInstallerStateVerifyingInPlace;
					state.installationStateAttempt = 1;
					return [state writeUsingDirectoryManager:self.directoryManager];
				}]
				setNameWithFormat:@"SQRLInstallerStateInstalling"];

		case SQRLInstallerStateVerifyingInPlace:
			return [[[[RACSignal
				zip:@[
					[self ensure:@keypath(state.targetBundleURL) fromState:state],
					[self ensure:@keypath(state.backupBundleURL) fromState:state],
					[self ensure:@keypath(state.codeSignature) fromState:state]
				] reduce:^(NSURL *targetBundleURL, NSURL *backupBundleURL, SQRLCodeSignature *codeSignature) {
					return [[self
						verifyBundleAtURL:targetBundleURL usingSignature:codeSignature recoveringUsingBackupAtURL:backupBundleURL]
						then:^{
							return [[self
								deleteBackupAtURL:backupBundleURL]
								catchTo:[RACSignal empty]];
						}];
				}]
				flatten]
				then:^{
					state.installerState = SQRLInstallerStateRelaunching;
					state.installationStateAttempt = 1;
					return [state writeUsingDirectoryManager:self.directoryManager];
				}]
				setNameWithFormat:@"SQRLInstallerStateVerifyingInPlace"];

		case SQRLInstallerStateRelaunching:
			return [[[[[RACSignal
				defer:^{
					if (state.relaunchAfterInstallation) {
						return [self ensure:@keypath(state.targetBundleURL) fromState:state];
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
				then:^{
					state.installerState = SQRLInstallerStateNothingToDo;
					state.installationStateAttempt = 1;
					return [state writeUsingDirectoryManager:self.directoryManager];
				}]
				setNameWithFormat:@"SQRLInstallerStateRelaunching"];
		
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

- (RACSignal *)backUpBundleAtURL:(NSURL *)targetBundleURL {
	NSParameterAssert(targetBundleURL != nil);

	return [[[[[[self.directoryManager
		applicationSupportURL]
		flattenMap:^(NSURL *applicationSupportURL) {
			NSError *error = nil;
			NSURL *temporaryDirectoryURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:applicationSupportURL create:YES error:&error];
			if (temporaryDirectoryURL == nil) {
				return [RACSignal error:error];
			}

			return [RACSignal return:temporaryDirectoryURL];
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
		setNameWithFormat:@"-backUpBundleAtURL: %@", targetBundleURL];
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

- (RACSignal *)verifyBundleAtURL:(NSURL *)bundleURL usingSignature:(SQRLCodeSignature *)signature recoveringUsingBackupAtURL:(NSURL *)backupBundleURL {
	NSParameterAssert(bundleURL != nil);
	NSParameterAssert(signature != nil);

	return [[[[signature
		verifyBundleAtURL:bundleURL]
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
		setNameWithFormat:@"-verifyBundleAtURL: %@ usingSignature: %@ recoveringUsingBackupAtURL: %@", bundleURL, signature, backupBundleURL];
}

#pragma mark Installation

- (RACSignal *)checkWhetherItemPreviouslyAtURL:(NSURL *)sourceURL wasInstalledAtURL:(NSURL *)targetURL usingSignature:(SQRLCodeSignature *)signature {
	NSParameterAssert(targetURL != nil);
	NSParameterAssert(sourceURL != nil);
	NSParameterAssert(signature != nil);

	return [[[[self
		verifyBundleAtURL:targetURL usingSignature:signature recoveringUsingBackupAtURL:nil]
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
