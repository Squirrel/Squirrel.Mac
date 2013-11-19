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
#import <copyfile.h>
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
const NSInteger SQRLInstallerErrorChangingPermissions = -8;

// Associated with a preferences key for the URL where the target bundle has
// been backed up to before installing the update.
//
// This is stored in preferences, rather than `SQRLShipItState`, to prevent an
// attacker from rewriting the URL during the installation process.
//
// Note that this key must remain backwards compatible, so ShipIt doesn't fail
// confusingly on a newer version.
static NSString * const SQRLInstallerBackupBundleURLKey = @"BackupBundleURL";

// Associated with a preferences key for the URL where the update bundle has
// been moved before installation.
//
// This is stored in preferences, rather than `SQRLShipItState`, to prevent an
// attacker from rewriting the URL during the installation process.
//
// Note that this key must remain backwards compatible, so ShipIt doesn't fail
// confusingly on a newer version.
static NSString * const SQRLInstallerUpdateBundleURLKey = @"UpdateBundleURL";

// Maps an installer state to a selector to invoke.
typedef struct {
	// The state for which the associated method should be invoked.
	SQRLInstallerState installerState;

	// A method accepting a `SQRLShipItState` argument and returning a cold
	// signal.
	//
	// If NULL, installation should complete.
	SEL selector;
} SQRLInstallerDispatchTableEntry;

static NSUInteger SQRLInstallerDispatchTableEntrySize(const void *_) {
	return sizeof(SQRLInstallerDispatchTableEntry);
}

@interface SQRLInstaller ()

// Finds the state file to read and write from.
@property (nonatomic, strong, readonly) SQRLDirectoryManager *directoryManager;

// The URL where the target bundle has been backed up to before installing the
// update.
@property (atomic, copy) NSURL *backupBundleURL;

// The URL where the update bundle has been moved before installation.
@property (atomic, copy) NSURL *updateBundleURL;

// Reads the given key from `state`, failing if it's not set.
//
// key   - The property key to read from `state`. This must not be nil, and
//         should refer to a property of object type.
// state - The state object to read. This must not be nil.
//
// Returns a signal which synchronously sends the non-nil read value then
// completes, or errors.
- (RACSignal *)getRequiredKey:(NSString *)key fromState:(SQRLShipItState *)state;

// Performs the remaining stages of installation, as specified by `state`.
//
// state - The installation state. This must not be nil.
//
// Returns a signal which will complete or error on an unspecified thread.
- (RACSignal *)resumeInstallationFromState:(SQRLShipItState *)state;

// Invokes -moveAndTakeOwnershipOfBundleAtURL: only if the bundle has not
// already been moved into place.
//
// bundleURL     - The original URL to the bundle. This must not be nil.
// installedURL  - The proposed destination URL for the bundle. This may be nil,
//                 in which case a new one will be generated.
// codeSignature - The code signature that any item must match in order to be
//                 considered the correct bundle. This may be nil if
//                 `installedURL` is nil.
//
// Returns a signal which will send the `NSURL` to the installed bundle location
// if a new one was generated, then complete once the bundle has been copied and
// its permissions updated. If the bundle was already in place, the signal will
// complete without sending any values.
- (RACSignal *)moveAndTakeOwnershipOfBundleAtURL:(NSURL *)bundleURL unlessInstalledAtURL:(NSURL *)installedURL verifiedUsingSignature:(SQRLCodeSignature *)codeSignature;

// Moves the specified bundle to a temporary location, then ensures that the
// bundle's permissions are such that other users and groups can't write to it.
//
// bundleURL - The URL to the bundle to move. This must not be nil.
//
// Returns a signal which will send the `NSURL` to the proposed new bundle
// location, as soon as one has been determined, then complete once the bundle
// has been copied and its permissions updated.
- (RACSignal *)moveAndTakeOwnershipOfBundleAtURL:(NSURL *)bundleURL;

// Deletes a bundle that was moved into place using -moveAndTakeOwnershipOfBundleAtURL:.
//
// bundleURL - The URL to the backup bundle, as sent from -moveAndTakeOwnershipOfBundleAtURL:.
//             This must not be nil.
//
// Returns a signal which will synchronously complete or error.
- (RACSignal *)deleteOwnedBundleAtURL:(NSURL *)bundleURL;

// Validates the code signature of a bundle, optionally restoring it upon
// failure.
//
// bundleURL       - The URL of the bundle whose code signature should be
//                   verified. This must not be nil.
// signature       - The code signature that the bundle must match. This must
//                   not be nil.
// backupBundleURL - If not nil, the URL to a bundle that should replace
//                   `bundleURL` if the code signature does not pass validation.
//
// Returns a signal which will synchronously complete if `bundleURL` passes
// validation, or if the bundle was recovered from `backupBundleURL`. If
// validation or recovery fails, an error will be sent.
- (RACSignal *)verifyBundleAtURL:(NSURL *)bundleURL usingSignature:(SQRLCodeSignature *)signature recoveringUsingBackupAtURL:(NSURL *)backupBundleURL;

// Attempts to determine whether a bundle has already been moved on disk.
//
// sourceURL - The original URL to the bundle. This must not be nil.
// targetURL - The proposed destination URL for the bundle. This must not be
//             nil.
// signature - The code signature that any item must match in order to be
//             considered the correct bundle. This must not be nil.
//
// Returns a signal which will synchronously send YES if `targetURL` points to
// a bundle matching the code signature, NO if it doesn't and `sourceURL` still
// exists, or an error otherwise.
- (RACSignal *)checkWhetherBundlePreviouslyAtURL:(NSURL *)sourceURL wasInstalledAtURL:(NSURL *)targetURL usingSignature:(SQRLCodeSignature *)signature;

// Moves `sourceURL` to `targetURL`.
//
// If the two URLs lie on the same volume, the installation will be performed
// atomically. Otherwise, the target item will be deleted, the source item will
// be copied to the target, then the source item will be deleted.
//
// targetURL - The URL to overwrite with the install. This must not be nil.
// sourceURL - The URL to move from. This must not be nil.
//
// Retruns a signal which will synchronously complete or error.
- (RACSignal *)installItemAtURL:(NSURL *)targetURL fromURL:(NSURL *)sourceURL;

// Recursively clears the quarantine extended attribute from the given
// directory.
//
// This ensures users don't see a warning that the application was downloaded
// from the Internet.
//
// directory - The directory to recursively clear the quarantine bit upon. This
//             must not be nil.
//
// Returns a signal which will send completed or error on a background thread.
- (RACSignal *)clearQuarantineForDirectory:(NSURL *)directory;

// Changes the owner and group of the given directory to that of the current process,
// then disables writing for anyone but the owner.
//
// directoryURL - The URL to the folder to take ownership of. This must not be
//                nil.
//
// Returns a signal which will synchronously complete or error.
- (RACSignal *)takeOwnershipOfDirectory:(NSURL *)directoryURL;

@end

@implementation SQRLInstaller

#pragma mark Properties

- (NSURL *)backupBundleURL {
	return [self URLForPreferencesKey:SQRLInstallerBackupBundleURLKey];
}

- (void)setBackupBundleURL:(NSURL *)URL {
	[self setURL:URL forPreferencesKey:SQRLInstallerBackupBundleURLKey];
}

- (NSURL *)updateBundleURL {
	return [self URLForPreferencesKey:SQRLInstallerUpdateBundleURLKey];
}

- (void)setUpdateBundleURL:(NSURL *)URL {
	[self setURL:URL forPreferencesKey:SQRLInstallerUpdateBundleURLKey];
}

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
			resumeInstallationFromState:state]
			sqrl_addTransactionWithName:NSLocalizedString(@"Updating", nil) description:NSLocalizedString(@"%@ is being updated, and interrupting the process could corrupt the application", nil), state.targetBundleURL.path];
	}];

	_abortInstallationCommand = [[RACCommand alloc] initWithEnabled:[self.installUpdateCommand.executing not] signalBlock:^(SQRLShipItState *state) {
		@strongify(self);
		NSParameterAssert(state != nil);

		return [[[RACSignal
			zip:@[
				[self getRequiredKey:@keypath(state.targetBundleURL) fromState:state],
				[self getRequiredKey:@keypath(state.codeSignature) fromState:state]
			] reduce:^(NSURL *targetBundleURL, SQRLCodeSignature *codeSignature) {
				return [self verifyBundleAtURL:targetBundleURL usingSignature:codeSignature recoveringUsingBackupAtURL:self.backupBundleURL];
			}]
			flatten]
			sqrl_addTransactionWithName:NSLocalizedString(@"Aborting update", nil) description:NSLocalizedString(@"An update to %@ is being rolled back, and interrupting the process could corrupt the application", nil), state.targetBundleURL.path];
	}];
	
	return self;
}

#pragma mark Preferences

- (NSURL *)URLForPreferencesKey:(NSString *)key {
	NSParameterAssert(key != nil);

	CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key, (__bridge CFStringRef)self.directoryManager.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);

	NSString *path = CFBridgingRelease(value);
	if (![path isKindOfClass:NSString.class]) return nil;

	return [NSURL fileURLWithPath:path];
}

- (void)setURL:(NSURL *)URL forPreferencesKey:(NSString *)key {
	NSParameterAssert(key != nil);

	CFStringRef applicationID = (__bridge CFStringRef)self.directoryManager.applicationIdentifier;

	CFPropertyListRef value = NULL;
	if (URL != nil) {
		NSURL *fileURL = URL.filePathURL;
		NSAssert(fileURL != nil, @"URL is not a file path URL: %@", URL);

		value = CFBridgingRetain(fileURL.path);
	}

	CFPreferencesSetValue((__bridge CFStringRef)key, value, applicationID, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
	if (value != NULL) CFRelease(value);

	if (!CFPreferencesSynchronize(applicationID, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)) {
		NSLog(@"Could not synchronize preferences for %@", applicationID);
	}
}

#pragma mark Installer States

+ (NSPointerArray *)stateDispatchTable {
	static NSPointerArray *dispatchTable = nil;
	static dispatch_once_t dispatchTablePredicate = 0;

	dispatch_once(&dispatchTablePredicate, ^{
		const SQRLInstallerDispatchTableEntry dispatchTablePrototype[] = {
			{ .installerState = SQRLInstallerStateUpdatingPermissions, .selector = @selector(moveUpdateBundleWithState:) },
			{ .installerState = SQRLInstallerStateBackingUp, .selector = @selector(backUpTargetWithState:) },
			{ .installerState = SQRLInstallerStateVerifyingTargetRequirement, .selector = @selector(verifyTargetDesignatedRequirementAgainstUpdateWithState:) },
			{ .installerState = SQRLInstallerStateClearingQuarantine, .selector = @selector(clearQuarantineWithState:) },
			{ .installerState = SQRLInstallerStateInstalling, .selector = @selector(installWithState:) },
			{ .installerState = SQRLInstallerStateVerifyingInPlace, .selector = @selector(verifyInPlaceWithState:) },
			{ .installerState = SQRLInstallerStateNothingToDo, .selector = NULL },
		};

		NSPointerFunctions *pointerFunctions = [[NSPointerFunctions alloc] initWithOptions:NSPointerFunctionsMallocMemory | NSPointerFunctionsStructPersonality | NSPointerFunctionsCopyIn];
		pointerFunctions.sizeFunction = SQRLInstallerDispatchTableEntrySize;
		dispatchTable = [[NSPointerArray alloc] initWithPointerFunctions:pointerFunctions];

		for (NSUInteger idx = 0; idx < sizeof(dispatchTablePrototype) / sizeof(*dispatchTablePrototype); idx++) {
			SQRLInstallerDispatchTableEntry const *entry = &dispatchTablePrototype[idx];
			[dispatchTable addPointer:(void *)entry];
		}
	});

	return dispatchTable;
}

+ (SQRLInstallerState)initialInstallerState {
	NSPointerArray *dispatchTable = self.stateDispatchTable;
	NSParameterAssert(dispatchTable.count >= 1);
	SQRLInstallerDispatchTableEntry *firstState = [dispatchTable pointerAtIndex:0];
	return firstState->installerState;
}

- (RACSignal *)getRequiredKey:(NSString *)key fromState:(SQRLShipItState *)state {
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
		setNameWithFormat:@"%@ -getRequiredKey: %@ fromState: %@", self, key, state];
}

- (RACSignal *)resumeInstallationFromState:(SQRLShipItState *)state {
	NSParameterAssert(state != nil);

	RACSignal *step = [RACSignal defer:^{
		NSPointerArray *dispatchTable = self.class.stateDispatchTable;

		SQRLInstallerState installerState = state.installerState;

		size_t tableIndex;
		for (tableIndex = 0; tableIndex < dispatchTable.count; tableIndex++) {
			SQRLInstallerDispatchTableEntry *currentEntry = [dispatchTable pointerAtIndex:tableIndex];
			if (currentEntry->installerState == installerState) {
				break;
			}
		}

		if (tableIndex >= dispatchTable.count) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Invalid installer state %i", nil), (int)installerState],
				NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Try installing the update again.", nil)
			};

			return [RACSignal error:[NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorInvalidState userInfo:userInfo]];
		}

		SQRLInstallerDispatchTableEntry *dispatch = [dispatchTable pointerAtIndex:tableIndex];
		SEL selector = dispatch->selector;
		if (selector == NULL) {
			// Nothing to do.
			return [RACSignal empty];
		}

		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:selector]];
		invocation.target = self;
		invocation.selector = selector;
		
		SQRLShipItState *stateArg = state;
		[invocation setArgument:&stateArg atIndex:2];
		[invocation invoke];

		__unsafe_unretained RACSignal *step = nil;
		[invocation getReturnValue:&step];

		SQRLInstallerDispatchTableEntry *nextDispatch = [dispatchTable pointerAtIndex:tableIndex + 1];
		SQRLInstallerState nextState = nextDispatch->installerState;

		return [[step
			doCompleted:^{
				NSLog(@"Completed state %i", (int)installerState);
			}]
			then:^{
				return [RACSignal return:@(nextState)];
			}];
	}];

	return [[self
		stepRepeatedly:step withState:state]
		setNameWithFormat:@"%@ -resumeInstallationFromState: %@", self, state];
}

- (RACSignal *)stepRepeatedly:(RACSignal *)step withState:(SQRLShipItState *)state {
	NSParameterAssert(step != nil);
	NSParameterAssert(state != nil);

	return [step flattenMap:^(NSNumber *nextState) {
		state.installerState = nextState.integerValue;
		state.installationStateAttempt = 1;
		return [[state
			writeUsingURL:self.directoryManager.shipItStateURL]
			// Automatically begin the next step.
			concat:[self stepRepeatedly:step withState:state]];
	}];
}

- (RACSignal *)moveUpdateBundleWithState:(SQRLShipItState *)state {
	NSParameterAssert(state != nil);

	return [[[[RACSignal
		zip:@[
			[self getRequiredKey:@keypath(state.updateBundleURL) fromState:state],
			[self getRequiredKey:@keypath(state.codeSignature) fromState:state]
		] reduce:^(NSURL *updateURL, SQRLCodeSignature *codeSignature) {
			return [self moveAndTakeOwnershipOfBundleAtURL:updateURL unlessInstalledAtURL:self.updateBundleURL verifiedUsingSignature:codeSignature];
		}]
		flatten]
		doNext:^(NSURL *updateBundleURL) {
			// Save the new URL as soon as we have it, so we can resume even if
			// the state change hasn't taken effect.
			self.updateBundleURL = updateBundleURL;
		}]
		setNameWithFormat:@"%@ -moveUpdateBundleWithState: %@", self, state];
}

- (RACSignal *)verifyTargetDesignatedRequirementAgainstUpdateWithState:(SQRLShipItState *)state {
	return [[[RACSignal
		defer:^{
			NSError *error;
			SQRLCodeSignature *codeSignature = [SQRLCodeSignature signatureWithBundle:self.backupBundleURL error:&error];
			if (codeSignature == nil) return [RACSignal error:error];

			return [codeSignature verifyBundleAtURL:self.updateBundleURL];
		}]
		flatten]
		setNameWithFormat:@"%@ -verifyTargetDesignatedRequirementAgainstUpdateWithState: %@", self, state];
}

- (RACSignal *)clearQuarantineWithState:(SQRLShipItState *)state {
	NSParameterAssert(state != nil);

	return [[RACSignal
		defer:^{
			return [self clearQuarantineForDirectory:self.updateBundleURL];
		}]
		setNameWithFormat:@"%@ -clearQuarantineWithState: %@", self, state];
}

- (RACSignal *)backUpTargetWithState:(SQRLShipItState *)state {
	NSParameterAssert(state != nil);

	return [[[[RACSignal
		zip:@[
			[self getRequiredKey:@keypath(state.targetBundleURL) fromState:state],
			[self getRequiredKey:@keypath(state.codeSignature) fromState:state]
		] reduce:^(NSURL *targetURL, SQRLCodeSignature *codeSignature) {
			return [self moveAndTakeOwnershipOfBundleAtURL:targetURL unlessInstalledAtURL:self.backupBundleURL verifiedUsingSignature:codeSignature];
		}]
		flatten]
		doNext:^(NSURL *backupBundleURL) {
			// Save the new URL as soon as we have it, so we can resume even if
			// the state change hasn't taken effect.
			self.backupBundleURL = backupBundleURL;
		}]
		setNameWithFormat:@"%@ -backUpTargetWithState: %@", self, state];
}

- (RACSignal *)installWithState:(SQRLShipItState *)state {
	NSParameterAssert(state != nil);

	return [[[RACSignal
		zip:@[
			[self getRequiredKey:@keypath(state.targetBundleURL) fromState:state],
			[self getRequiredKey:@keypath(state.codeSignature) fromState:state]
		] reduce:^(NSURL *targetBundleURL, SQRLCodeSignature *codeSignature) {
			return [[[[self
				checkWhetherBundlePreviouslyAtURL:self.updateBundleURL wasInstalledAtURL:targetBundleURL usingSignature:codeSignature]
				flattenMap:^(NSNumber *skip) {
					if (skip.boolValue) {
						return [RACSignal empty];
					} else {
						return [self installItemAtURL:targetBundleURL fromURL:self.updateBundleURL];
					}
				}]
				catch:^(NSError *error) {
					NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Failed to replace bundle %@ with update %@", nil), targetBundleURL, self.updateBundleURL];
					return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorReplacingTarget toError:error]];
				}]
				catch:^(NSError *error) {
					// Verify that the target bundle didn't get corrupted during
					// failure. Try recovering it if it did.
					return [[self
						verifyBundleAtURL:targetBundleURL usingSignature:codeSignature recoveringUsingBackupAtURL:self.backupBundleURL]
						then:^{
							// Recovery succeeded, but we still want to pass
							// through the original error.
							return [RACSignal error:error];
						}];
				}];
		}]
		flatten]
		setNameWithFormat:@"%@ -installWithState: %@", self, state];
}

- (RACSignal *)verifyInPlaceWithState:(SQRLShipItState *)state {
	NSParameterAssert(state != nil);

	return [[[RACSignal
		zip:@[
			[self getRequiredKey:@keypath(state.targetBundleURL) fromState:state],
			[self getRequiredKey:@keypath(state.codeSignature) fromState:state]
		] reduce:^(NSURL *targetBundleURL, SQRLCodeSignature *codeSignature) {
			NSURL *backupBundleURL = self.backupBundleURL;

			return [[self
				verifyBundleAtURL:targetBundleURL usingSignature:codeSignature recoveringUsingBackupAtURL:nil]
				then:^{
					NSURL *updateBundleURL = self.updateBundleURL;

					// Clean up our temporary locations.
					return [[RACSignal
						merge:@[
							[[self deleteOwnedBundleAtURL:backupBundleURL] catchTo:[RACSignal empty]],
							[[self deleteOwnedBundleAtURL:updateBundleURL] catchTo:[RACSignal empty]],
						]]
						doCompleted:^{
							self.backupBundleURL = nil;
							self.updateBundleURL = nil;
						}];
				}];
		}]
		flatten]
		setNameWithFormat:@"%@ -verifyInPlaceWithState: %@", self, state];
}

#pragma mark Backing Up

- (RACSignal *)moveAndTakeOwnershipOfBundleAtURL:(NSURL *)bundleURL unlessInstalledAtURL:(NSURL *)installedURL verifiedUsingSignature:(SQRLCodeSignature *)codeSignature {
	NSParameterAssert(bundleURL != nil);

	return [[RACSignal
		defer:^{
			RACSignal *skipMove = [RACSignal return:@NO];
			if (installedURL != nil) {
				skipMove = [[self
					takeOwnershipOfDirectory:installedURL]
					then:^{
						return [self checkWhetherBundlePreviouslyAtURL:bundleURL wasInstalledAtURL:installedURL usingSignature:codeSignature];
					}];
			}

			return [[skipMove
				ignore:@YES]
				flattenMap:^(id _) {
					return [self moveAndTakeOwnershipOfBundleAtURL:bundleURL];
				}];
		}]
		setNameWithFormat:@"%@ -moveAndTakeOwnershipOfBundleAtURL: %@ unlessInstalledAtURL: %@ verifiedUsingSignature: %@", self, bundleURL, installedURL, codeSignature];
}

- (RACSignal *)moveAndTakeOwnershipOfBundleAtURL:(NSURL *)bundleURL {
	NSParameterAssert(bundleURL != nil);

	return [[[[[RACSignal
		defer:^{
			NSString *tmpPath = [NSTemporaryDirectory() stringByResolvingSymlinksInPath];
			NSString *template = [NSString stringWithFormat:@"%@.XXXXXXXX", self.directoryManager.applicationIdentifier];

			char *fullTemplate = strdup([tmpPath stringByAppendingPathComponent:template].UTF8String);
			@onExit {
				free(fullTemplate);
			};

			if (mkdtemp(fullTemplate) == NULL) {
				return [RACSignal error:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]];
			}

			NSURL *URL = [NSURL fileURLWithPath:[NSFileManager.defaultManager stringWithFileSystemRepresentation:fullTemplate length:strlen(fullTemplate)] isDirectory:YES];
			return [RACSignal return:URL];
		}]
		catch:^(NSError *error) {
			NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Could not create temporary folder", nil)];
			return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorBackupFailed toError:error]];
		}]
		map:^(NSURL *temporaryDirectoryURL) {
			return [temporaryDirectoryURL URLByAppendingPathComponent:bundleURL.lastPathComponent];
		}]
		flattenMap:^(NSURL *newBundleURL) {
			return [[[[[self
				installItemAtURL:newBundleURL fromURL:bundleURL]
				catch:^(NSError *error) {
					NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Failed to move bundle %@ to temporary location %@", nil), bundleURL, newBundleURL];
					return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorBackupFailed toError:error]];
				}]
				then:^{
					return [self takeOwnershipOfDirectory:newBundleURL];
				}]
				ignoreValues]
				// Return the new URL before doing any work, to increase fault
				// tolerance.
				startWith:newBundleURL];
		}]
		setNameWithFormat:@"%@ -moveAndTakeOwnershipOfBundleAtURL: %@", self, bundleURL];
}

- (RACSignal *)deleteOwnedBundleAtURL:(NSURL *)bundleURL {
	NSParameterAssert(bundleURL != nil);

	return [[[RACSignal
		defer:^{
			NSError *error = nil;
			if ([NSFileManager.defaultManager removeItemAtURL:bundleURL error:&error]) {
				return [RACSignal empty];
			} else {
				return [RACSignal error:error];
			}
		}]
		then:^{
			// Also remove the temporary directory that the backup lived in.
			NSURL *temporaryDirectoryURL = bundleURL.URLByDeletingLastPathComponent;

			// However, use rmdir() to skip it in case there are other files
			// contained within (for whatever reason).
			if (rmdir(temporaryDirectoryURL.path.fileSystemRepresentation) == 0) {
				return [RACSignal empty];
			} else {
				return [RACSignal error:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]];
			}
		}]
		setNameWithFormat:@"%@ -deleteOwnedBundleAtURL: %@", self, bundleURL];
}

- (RACSignal *)verifyBundleAtURL:(NSURL *)bundleURL usingSignature:(SQRLCodeSignature *)signature recoveringUsingBackupAtURL:(NSURL *)backupBundleURL {
	NSParameterAssert(bundleURL != nil);
	NSParameterAssert(signature != nil);

	return [[[signature
		verifyBundleAtURL:bundleURL]
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
		setNameWithFormat:@"%@ -verifyBundleAtURL: %@ usingSignature: %@ recoveringUsingBackupAtURL: %@", self, bundleURL, signature, backupBundleURL];
}

#pragma mark Installation

- (RACSignal *)checkWhetherBundlePreviouslyAtURL:(NSURL *)sourceURL wasInstalledAtURL:(NSURL *)targetURL usingSignature:(SQRLCodeSignature *)signature {
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
		setNameWithFormat:@"%@ -checkWhetherBundlePreviouslyAtURL: %@ wasInstalledAtURL: %@", self, sourceURL, targetURL];
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
		setNameWithFormat:@"%@ -installItemAtURL: %@ fromURL: %@", self, targetURL, sourceURL];
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
		setNameWithFormat:@"%@ -clearQuarantineForDirectory: %@", self, directory];
}

#pragma mark File Security

- (RACSignal *)readFileSecurityOfURL:(NSURL *)location {
	NSParameterAssert(location != nil);

	return [[RACSignal
		defer:^{
			NSError *error;
			NSFileSecurity *fileSecurity;
			if (![location getResourceValue:&fileSecurity forKey:NSURLFileSecurityKey error:&error]) {
				return [RACSignal error:error];
			}

			return [RACSignal return:fileSecurity];
		}]
		setNameWithFormat:@"%@ -readFileSecurity: %@", self, location];
}

- (RACSignal *)writeFileSecurity:(NSFileSecurity *)fileSecurity toURL:(NSURL *)location {
	NSParameterAssert(location != nil);

	return [[RACSignal
		defer:^{
			NSError *error;
			if (![location setResourceValue:fileSecurity forKey:NSURLFileSecurityKey error:&error]) {
				return [RACSignal error:error];
			}

			return [RACSignal empty];
		}]
		setNameWithFormat:@"%@ -writeFileSecurity: %@", self, location];
}

- (RACSignal *)takeOwnershipOfDirectory:(NSURL *)directoryURL {
	NSParameterAssert(directoryURL != nil);

	return [[[RACSignal
		createSignal:^(id<RACSubscriber> subscriber) {
			NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:directoryURL includingPropertiesForKeys:@[ NSURLFileSecurityKey ] options:0 errorHandler:^ BOOL (NSURL *url, NSError *error) {
				[subscriber sendError:error];
				return NO;
			}];

			return [enumerator.rac_sequence.signal subscribe:subscriber];
		}]
		flattenMap:^(NSURL *itemURL) {
			return [[[self
				readFileSecurityOfURL:itemURL]
				flattenMap:^(NSFileSecurity *fileSecurity) {
					if (![self takeOwnershipOfFileSecurity:fileSecurity]) {
						NSDictionary *errorInfo = @{
							NSLocalizedDescriptionKey: NSLocalizedString(@"Permissions Error", nil),
							NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn’t update permissions of %@", nil), itemURL.path],
							NSURLErrorKey: itemURL
						};

						return [RACSignal error:[NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorChangingPermissions userInfo:errorInfo]];
					}

					return [RACSignal return:fileSecurity];
				}]
				flattenMap:^(NSFileSecurity *fileSecurity) {
					return [self writeFileSecurity:fileSecurity toURL:itemURL];
				}];
		}]
		setNameWithFormat:@"%@ -takeOwnershipOfDirectory: %@", self, directoryURL];
}

- (BOOL)takeOwnershipOfFileSecurity:(NSFileSecurity *)fileSecurity {
	CFFileSecurityRef actualFileSecurity = (__bridge CFFileSecurityRef)fileSecurity;

	// If ShipIt is running as root, this will change the owner to
	// root:wheel.
	if (!CFFileSecuritySetOwner(actualFileSecurity, getuid())) return NO;
	if (!CFFileSecuritySetGroup(actualFileSecurity, getgid())) return NO;

	mode_t fileMode = 0;
	if (!CFFileSecurityGetMode(actualFileSecurity, &fileMode)) return NO;

	// Remove write permission from group and other, leave executable
	// bit as it was for both.
	//
	// Permissions will be r-(x?)r-(x?) afterwards, with owner
	// permissions left as is.
	fileMode = (fileMode & ~(S_IWGRP | S_IWOTH));

	return CFFileSecuritySetMode(actualFileSecurity, fileMode);
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
