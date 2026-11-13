//
//  SQRLInstaller.m
//  Squirrel
//
//  Created by Alan Rogers on 30/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLInstaller.h"

#import <libkern/OSAtomic.h>
#import <mach-o/dyld.h>
#import <sys/param.h>
#import <unistd.h>
#import <ReactiveObjC/EXTKeyPathCoding.h>
#import <ReactiveObjC/EXTScope.h>
#import <ReactiveObjC/NSEnumerator+RACSequenceAdditions.h>
#import <ReactiveObjC/NSObject+RACPropertySubscribing.h>
#import <ReactiveObjC/RACCommand.h>
#import <ReactiveObjC/RACSequence.h>
#import <ReactiveObjC/RACSignal+Operations.h>
#import <ReactiveObjC/RACSubscriber.h>
#import <sys/xattr.h>
#import <copyfile.h>
#import <signal.h>
#import <sys/stat.h>

#import "NSBundle+SQRLVersionExtensions.h"
#import "NSError+SQRLVerbosityExtensions.h"
#import "RACSignal+SQRLTransactionExtensions.h"
#import "SQRLCodeSignature.h"
#import "SQRLShipItRequest.h"
#import "SQRLTerminationListener.h"
#import "SQRLInstallerOwnedBundle.h"

NSString * const SQRLInstallerErrorDomain = @"SQRLInstallerErrorDomain";

const NSInteger SQRLInstallerErrorBackupFailed = -1;
const NSInteger SQRLInstallerErrorReplacingTarget = -2;
const NSInteger SQRLInstallerErrorCouldNotOpenTarget = -3;
const NSInteger SQRLInstallerErrorInvalidBundleVersion = -4;
const NSInteger SQRLInstallerErrorMissingInstallationData = -5;
const NSInteger SQRLInstallerErrorInvalidState = -6;
const NSInteger SQRLInstallerErrorMovingAcrossVolumes = -7;
const NSInteger SQRLInstallerErrorChangingPermissions = -8;
const NSInteger SQRLInstallerErrorAppStillRunning = -9;

NSString * const SQRLShipItInstallationAttemptsKey = @"SQRLShipItInstallationAttempts";
NSString * const SQRLInstallerOwnedBundleKey = @"SQRLInstallerOwnedBundle";
static NSString * const SQRLInstallerPendingCleanupKey = @"SQRLInstallerPendingCleanup";
static NSString * const SQRLInstallerPreparedBundlePathKey = @"SQRLInstallerPreparedBundlePath";

@interface SQRLInstaller ()

// The defaults domain to store all resumable state in.
@property (nonatomic, copy, readonly) NSString *applicationIdentifier;

// The bundle currently owned by this installer.
//
// Stores the bundle moved aside by an install request so that the original
// bundle can be restored to its original location if needed.
@property (atomic, strong) SQRLInstallerOwnedBundle *ownedBundle;
@property (atomic, strong) SQRLShipItRequest *preparedRequest;
@property (atomic, copy) NSURL *preparedBundleURL;

// Reads the given key from `request`, failing if it's not set.
//
// key     - The property key to read from `request`. This must not be nil, and
//           should refer to a property of object type.
// request - The request object to read. This must not be nil.
//
// Returns a signal which synchronously sends the non-nil read value then
// completes, or errors.
- (RACSignal *)getRequiredKey:(NSString *)key fromRequest:(SQRLShipItRequest *)request;

// Moves the updateBundleURL to an owned directory to prevent symlink attack,
// takes user:group ownership of the bundle, then verifies that it meets the
// designated requirement of the targetBundleURL.
//
// request - The request whose update should be prepared and validated.
//
// Returns a signal which sends the owned & validated bundle URL then completes,
// or errors.
- (RACSignal *)prepareAndValidateUpdateBundleURLForRequest:(SQRLShipItRequest *)request;

// Saves a `SQRLInstallerOwnedBundle` for the targetBundleURL to the
// preferences, then moves the targetBundleURL to an owned directory.
//
// request - The request whose target should be removed in preparation of an
//           update being installed.
//
// Returns a signal which completes, or errors.
- (RACSignal *)acquireTargetBundleURLForRequest:(SQRLShipItRequest *)request;

// Deletes a bundle that was moved into place using -moveAndTakeOwnershipOfBundleAtURL:.
//
// bundleURL - The URL to the backup bundle, as sent from -moveAndTakeOwnershipOfBundleAtURL:.
//             This must not be nil.
//
// Returns a signal which will synchronously complete or error.
- (RACSignal *)deleteOwnedBundleAtURL:(NSURL *)bundleURL;

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
- (RACSignal *)installItemToURL:(NSURL *)targetURL fromURL:(NSURL *)sourceURL;

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

// Recursively changes the owner and group of the given directory tree to that
// of the current process, then disables writing for anyone but the owner.
//
// directoryURL - The URL to the folder to take ownership of. This must not be
//                nil.
//
// Returns a signal which will synchronously complete or error.
- (RACSignal *)takeOwnershipOfDirectory:(NSURL *)directoryURL;

@end

@implementation SQRLInstaller

#pragma mark Lifecycle

- (id)initWithApplicationIdentifier:(NSString *)applicationIdentifier {
	NSParameterAssert(applicationIdentifier != nil);

	self = [super init];
	if (self == nil) return nil;

	_applicationIdentifier = [applicationIdentifier copy];

	@weakify(self);

	RACSignal *aborting = [[[[RACObserve(self, abortInstallationCommand)
		ignore:nil]
		map:^(RACCommand *command) {
			return command.executing;
		}]
		switchToLatest]
		setNameWithFormat:@"aborting"];

	_installUpdateCommand = [[RACCommand alloc] initWithEnabled:[aborting not] signalBlock:^(SQRLShipItRequest *request) {
		@strongify(self);
		NSParameterAssert(request != nil);

		// Request can be changed between launches, the installer may have
		// already have an owned bundle, for a previous targetURL.
		//
		// If that's the case, we need to abort the previous owned bundle, and
		// then handle the new install request.
		RACSignal *preparePreviousState = (self.ownedBundle == nil ? [RACSignal empty] : [[[[self
			abortInstall]
			doError:^(NSError *error) {
				NSLog(@"Couldn't abort install and restore owned bundle to previous location %@, error %@", self.ownedBundle.originalURL, error.sqrl_verboseDescription);
			}]
			catch:^(NSError *error) {
				// Do not overwrite durable cleanup state with a new rollback
				// record if obsolete bundles could not be removed.
				return self.ownedBundle.cleanupURLs != nil ? [RACSignal error:error] : [RACSignal empty];
			}]
			ignoreValues]);

		return [preparePreviousState then:^{
			return [self installRequest:request];
		}];
	}];

	_abortInstallationCommand = [[RACCommand alloc] initWithEnabled:[self.installUpdateCommand.executing not] signalBlock:^(SQRLShipItRequest *request) {
		@strongify(self);

		return [self abortInstall];
	}];

	return self;
}

#pragma mark Preferences

- (SQRLInstallerOwnedBundle *)ownedBundle {
	id archiveData = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)SQRLInstallerOwnedBundleKey, (__bridge CFStringRef)self.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost));
	if (![archiveData isKindOfClass:NSData.class]) return nil;

	// unarchivedObjectOfClass:fromData:error: sets secureCoding to true and we don't
	// archive data with secureCoding enabled - use our own unarchiver to work around that.
	NSError *error;
	NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:archiveData
                                                                              error:&error];
	unarchiver.requiresSecureCoding = NO;
	SQRLInstallerOwnedBundle *ownedBundle = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
	[unarchiver finishDecoding];

	if (error) {
		NSLog(@"Error while unarchiving ownedBundle - %@", error.localizedDescription);
		return nil;
	}

	if (!ownedBundle || ![ownedBundle isKindOfClass:SQRLInstallerOwnedBundle.class]) {
		NSLog(@"Unknown error while unarchiving ownedBundle - did not conform to SQRLInstallerOwnedBundle");
		return nil;
	}

	return ownedBundle;
}

- (void)setOwnedBundle:(SQRLInstallerOwnedBundle *)ownedBundle {
	NSError *error = nil;
	if (![self saveOwnedBundle:ownedBundle error:&error]) {
		NSLog(@"Could not persist installer state: %@", error);
	}
}

- (BOOL)saveOwnedBundle:(SQRLInstallerOwnedBundle *)ownedBundle error:(NSError **)error {
	NSData *archiveData = nil;
	if (ownedBundle != nil) {
		archiveData = [NSKeyedArchiver archivedDataWithRootObject:ownedBundle
													requiringSecureCoding:NO
																					error:error];
		if (archiveData == nil) return NO;
	}

	CFPreferencesSetValue((__bridge CFStringRef)SQRLInstallerOwnedBundleKey, (__bridge CFPropertyListRef)archiveData, (__bridge CFStringRef)self.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
	if (CFPreferencesSynchronize((__bridge CFStringRef)self.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)) return YES;
	if (error != NULL) {
		*error = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorInvalidState userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not persist installer state", nil) }];
	}
	return NO;
}

#pragma mark Properties

- (RACSignal *)getRequiredKey:(NSString *)key fromRequest:(SQRLShipItRequest *)request {
	NSParameterAssert(key != nil);
	NSParameterAssert(request != nil);

	return [[RACSignal
		defer:^{
			id value = [request valueForKey:key];
			if (value == nil) {
				NSString *errorDescription = [NSString stringWithFormat:NSLocalizedString(@"Missing %@", nil), key];
				return [RACSignal error:[self missingDataErrorWithDescription:errorDescription]];
			} else {
				return [RACSignal return:value];
			}
		}]
		setNameWithFormat:@"%@ -getRequiredKey: %@ fromRequest: %@", self, key, request];
}

#pragma mark Installer States

- (BOOL)isPreparedDirectoryOwnerAndLocked:(NSURL *)directoryURL requirePrivateDirectory:(BOOL)requirePrivateDirectory {
	if (directoryURL == nil) return NO;
	struct stat sb;
	if (lstat(directoryURL.path.fileSystemRepresentation, &sb) != 0) return NO;
	if (!S_ISDIR(sb.st_mode)) return NO;
	if (sb.st_uid != getuid()) return NO;
	mode_t forbiddenMask = requirePrivateDirectory ? (S_IRWXG | S_IRWXO) : (S_IWGRP | S_IWOTH);
	if ((sb.st_mode & forbiddenMask) != 0) return NO;
	return YES;
}

- (RACSignal *)prepareAndValidateUpdateBundleURLForRequest:(SQRLShipItRequest *)request {
	NSParameterAssert(request != nil);

	if (!request.earlyStaging) {
		RACSignal *legacyPrepare = [[[[[[[self
			ownedTemporaryDirectoryURL]
			flattenMap:^(NSURL *directoryURL) {
				return [self copyBundleAtURL:request.updateBundleURL toDirectory:directoryURL];
			}]
			flattenMap:^(NSURL *bundleURL) {
				return [[[self
					clearQuarantineForDirectory:bundleURL]
					ignoreValues]
					concat:[RACSignal return:bundleURL]];
			}]
			zipWith:[self codeSignatureForBundleAtURL:request.targetBundleURL]]
			reduceEach:^(NSURL *updateBundleURL, SQRLCodeSignature *codeSignature) {
				return [[[self
					verifyBundleAtURL:updateBundleURL usingSignature:codeSignature]
					ignoreValues]
					concat:[RACSignal return:updateBundleURL]];
			}]
			flatten]
			setNameWithFormat:@"%@ -prepareAndValidateUpdateBundleURLForRequest: %@", self, request];
		return [RACSignal defer:^{
			if (self.preparedBundleURL == nil) return legacyPrepare;
			return [[self discardPreparedBundle] then:^{
				return legacyPrepare;
			}];
		}];
	}

	RACSignal *candidate;
	if ([self.preparedRequest matchesPreparedRequest:request] &&
		self.preparedBundleURL != nil &&
		[self isPreparedDirectoryOwnerAndLocked:self.preparedBundleURL.URLByDeletingLastPathComponent requirePrivateDirectory:YES] &&
		[self isPreparedDirectoryOwnerAndLocked:self.preparedBundleURL requirePrivateDirectory:NO]) {
		NSLog(@"Using prepared bundle for %@", request.updateBundleURL);
		candidate = [RACSignal return:self.preparedBundleURL];
	} else {
		candidate = [[self discardPreparedBundle] then:^{
			return [self stageUpdateForRequest:request];
		}];
	}

	return [[[[candidate
		zipWith:[self codeSignatureForBundleAtURL:request.targetBundleURL]]
		reduceEach:^(NSURL *updateBundleURL, SQRLCodeSignature *codeSignature) {
			// Call -verifyBundleAtURL: directly rather than
			// -verifyBundleAtURL:usingSignature: because -stageUpdateForRequest:
			// already normalized ownership and locked the private 0700 parent
			// directory (verified via lstat above), avoiding a second full-bundle
			// CFFileSecurity walk on the post-quit critical path. A fresh
			// SQRLCodeSignature is still required so cached validation is never
			// reused across the wait.
			return [[[codeSignature verifyBundleAtURL:updateBundleURL]
				ignoreValues]
				concat:[RACSignal return:updateBundleURL]];
		}]
		flatten]
		setNameWithFormat:@"%@ -prepareAndValidateUpdateBundleURLForRequest: %@", self, request];
}

- (void)setPersistedPreparedBundleURL:(NSURL *)URL {
	CFPreferencesSetValue((__bridge CFStringRef)SQRLInstallerPreparedBundlePathKey, (__bridge CFStringRef)URL.path, (__bridge CFStringRef)self.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
	CFPreferencesSynchronize((__bridge CFStringRef)self.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
}

- (NSURL *)persistedPreparedBundleURL {
	id path = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)SQRLInstallerPreparedBundlePathKey, (__bridge CFStringRef)self.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost));
	if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) return nil;
	return [NSURL fileURLWithPath:path];
}

- (RACSignal *)discardOrphanedPreparedBundle {
	return [RACSignal defer:^{
		NSURL *inMemoryURL = self.preparedBundleURL;
		NSURL *persistedURL = [self persistedPreparedBundleURL];
		if (persistedURL == nil || [persistedURL.path isEqualToString:inMemoryURL.path]) return [RACSignal empty];
		[self setPersistedPreparedBundleURL:inMemoryURL];
		return [[self deleteOwnedBundleAtURL:persistedURL] catchTo:[RACSignal empty]];
	}];
}

- (RACSignal *)discardPreparedBundle {
	return [RACSignal defer:^{
		NSURL *inMemoryURL = self.preparedBundleURL;
		NSURL *persistedURL = [self persistedPreparedBundleURL];
		self.preparedRequest = nil;
		if (inMemoryURL == nil && persistedURL == nil) return [RACSignal empty];

		self.preparedBundleURL = nil;
		if (persistedURL != nil) {
			[self setPersistedPreparedBundleURL:nil];
		}

		RACSignal *deleteInMemory = (inMemoryURL == nil) ? [RACSignal empty] : [[self deleteOwnedBundleAtURL:inMemoryURL] catchTo:[RACSignal empty]];
		RACSignal *deletePersisted = (persistedURL == nil || [persistedURL.path isEqualToString:inMemoryURL.path]) ? [RACSignal empty] : [[self deleteOwnedBundleAtURL:persistedURL] catchTo:[RACSignal empty]];
		return [deleteInMemory concat:deletePersisted];
	}];
}

- (RACSignal *)prepareRequest:(SQRLShipItRequest *)request {
	return [[self validateTargetForRequest:request] flattenMap:^(SQRLShipItRequest *validatedRequest) {
		return [[self discardPreparedBundle] then:^{
			return [[self stageUpdateForRequest:validatedRequest] doNext:^(NSURL *URL) {
				self.preparedBundleURL = URL;
				self.preparedRequest = validatedRequest;
				[self setPersistedPreparedBundleURL:URL];
				NSLog(@"Prepared bundle for %@", validatedRequest.updateBundleURL);
			}];
		}];
	}];
}

- (RACSignal *)stageUpdateForRequest:(SQRLShipItRequest *)request {
	__block NSURL *candidateURL = nil;
	return [[[[[self
		ownedTemporaryDirectoryURL]
		flattenMap:^(NSURL *directoryURL) {
			candidateURL = [directoryURL URLByAppendingPathComponent:request.updateBundleURL.lastPathComponent];
			[self setPersistedPreparedBundleURL:candidateURL];
			return [self copyBundleAtURL:request.updateBundleURL toDirectory:directoryURL useClone:YES];
		}]
		flattenMap:^(NSURL *bundleURL) {
			return [[[[self clearQuarantineForDirectory:bundleURL]
				then:^{
					return [self takeOwnershipOfDirectory:bundleURL stripACLs:YES];
				}]
				ignoreValues]
				then:^{
					if (chmod(bundleURL.URLByDeletingLastPathComponent.path.fileSystemRepresentation, S_IRWXU) != 0) {
						return [RACSignal error:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]];
					}
					return [RACSignal return:bundleURL];
				}];
		}]
		catch:^(NSError *error) {
			if (candidateURL == nil) return [RACSignal error:error];
			[self setPersistedPreparedBundleURL:nil];
			return [[[self deleteOwnedBundleAtURL:candidateURL] doError:^(NSError *cleanupError) {
				NSLog(@"Could not clean failed preparation: %@", cleanupError);
			}] concat:[RACSignal error:error]];
		}]
		setNameWithFormat:@"%@ -stageUpdateForRequest: %@", self, request];
}

- (RACSignal *)acquireTargetBundleURLForRequest:(SQRLShipItRequest *)request {
	NSParameterAssert(request != nil);

	return [[[[RACSignal
		zip:@[
			[self ownedTemporaryDirectoryURL],
			[self codeSignatureForBundleAtURL:request.targetBundleURL],
		] reduce:^(NSURL *directoryURL, SQRLCodeSignature *codeSignature) {
			NSURL *targetBundleURL = request.targetBundleURL;
			NSURL *newBundleURL = [directoryURL URLByAppendingPathComponent:targetBundleURL.lastPathComponent];
			[NSFileManager.defaultManager createDirectoryAtURL:newBundleURL withIntermediateDirectories:FALSE attributes:nil error:nil];

			return [[SQRLInstallerOwnedBundle alloc] initWithOriginalURL:request.targetBundleURL temporaryURL:newBundleURL codeSignature:codeSignature];
		}]
		doNext:^(SQRLInstallerOwnedBundle *ownedBundle) {
			self.ownedBundle = ownedBundle;
		}]
		flattenMap:^(SQRLInstallerOwnedBundle *ownedBundle) {
			return [self installItemToURL:ownedBundle.temporaryURL fromURL:ownedBundle.originalURL];
		}]
		setNameWithFormat:@"%@ -acquireTargetBundleURLForRequest: %@", self, request];
}

- (RACSignal *)renameIfNeeded:(SQRLShipItRequest *)request updateBundleURL:(NSURL *)updateBundleURL {
	if (!request.useUpdateBundleName) return [RACSignal return:request];

	return [[self
		renamedTargetIfNeededWithTargetURL:request.targetBundleURL sourceURL:updateBundleURL]
		flattenMap:^(NSURL *newTargetURL) {
			if ([newTargetURL isEqual:request.targetBundleURL]) return [RACSignal return:request];

			NSMutableDictionary *values = [request.dictionaryValue mutableCopy];
			values[@keypath(request.targetBundleURL)] = newTargetURL;
			NSError *error = nil;
			SQRLShipItRequest *updatedRequest = [[SQRLShipItRequest alloc] initWithDictionary:values error:&error];
			if (updatedRequest == nil) return [RACSignal error:error];
			return [[self
				installItemToURL:newTargetURL fromURL:request.targetBundleURL]
				concat:[RACSignal return:updatedRequest]];
		}];
}

- (RACSignal *)validateTargetForRequest:(SQRLShipItRequest *)request {
	NSParameterAssert(request != nil);

	// Resolve the target bundle path exactly once and use the canonical URL for
	// every step of the install chain. The request is read from disk, so the
	// path it carries is untrusted; every downstream step that re-resolves it
	// must see the same location that validation saw.
	NSURL *resolvedTargetURL = request.targetBundleURL.URLByResolvingSymlinksInPath.URLByStandardizingPath;
	if (![resolvedTargetURL.path isEqual:request.targetBundleURL.URLByStandardizingPath.path]) {
		NSDictionary *errorInfo = @{
			NSLocalizedDescriptionKey: NSLocalizedString(@"Target bundle path is not canonical", nil),
			NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"The target bundle path must not traverse symbolic links.", nil),
		};
		return [RACSignal error:[NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorInvalidState userInfo:errorInfo]];
	}

	// When running privileged, the target must be the app bundle that contains
	// this installer. This pins the install to a location whose ancestors the
	// user that wrote the request cannot modify.
	if (geteuid() == 0) {
		NSString *expectedTargetPath = nil;
		char rawPath[PATH_MAX] = {0};
		char canonicalPath[PATH_MAX] = {0};
		uint32_t rawPathSize = sizeof(rawPath);
		if (_NSGetExecutablePath(rawPath, &rawPathSize) == 0 && realpath(rawPath, canonicalPath) != NULL) {
			NSArray<NSString *> *components = @(canonicalPath).pathComponents;
			for (NSInteger i = (NSInteger)components.count - 1; i >= 0; i--) {
				if ([components[(NSUInteger)i] hasSuffix:@".app"]) {
					NSURL *expectedURL = [NSURL fileURLWithPath:[NSString pathWithComponents:[components subarrayWithRange:NSMakeRange(0, (NSUInteger)i + 1)]]];
					expectedTargetPath = expectedURL.URLByStandardizingPath.path;
					break;
				}
			}
		}
		if (expectedTargetPath == nil || ![resolvedTargetURL.path isEqual:expectedTargetPath]) {
			NSLog(@"Privileged install rejected: target %@ does not match installer bundle %@", resolvedTargetURL.path, expectedTargetPath);
			NSDictionary *errorInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Target bundle does not match installer location", nil),
				NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"When running with elevated privileges, the target bundle must be the application that contains this installer.", nil),
			};
			return [RACSignal error:[NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorInvalidState userInfo:errorInfo]];
		}
	}

	NSMutableDictionary *values = [request.dictionaryValue mutableCopy];
	values[@keypath(request.targetBundleURL)] = resolvedTargetURL;
	NSError *error = nil;
	SQRLShipItRequest *canonicalRequest = [[SQRLShipItRequest alloc] initWithDictionary:values error:&error];
	return canonicalRequest == nil ? [RACSignal error:error] : [RACSignal return:canonicalRequest];
}

- (RACSignal *)installRequest:(SQRLShipItRequest *)request {
	return [[self validateTargetForRequest:request] flattenMap:^(SQRLShipItRequest *validatedRequest) {
		return [self installValidatedRequest:validatedRequest];
	}];
}

- (RACSignal *)installValidatedRequest:(SQRLShipItRequest *)request {
	return [[[[self
		prepareAndValidateUpdateBundleURLForRequest:request]
		flattenMap:^(NSURL *updateBundleURL) {
			return [[[[self
				renameIfNeeded:request updateBundleURL:updateBundleURL]
				flattenMap:^(SQRLShipItRequest *renamedRequest) {
					// Final validation that the application is not running again;
					NSArray *apps = nil;
					if (renamedRequest.bundleIdentifier != nil) {
						apps = [[NSRunningApplication runningApplicationsWithBundleIdentifier:renamedRequest.bundleIdentifier] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSRunningApplication *app, NSDictionary *bindings) {
							if (![[[app bundleURL] URLByStandardizingPath] isEqual:renamedRequest.targetBundleURL]) return NO;
							if (app.processIdentifier <= 0) return NO;
							// LaunchServices can still list an exited process just
							// after the termination listener's kernel notification.
							// Treat every error except ESRCH as potentially running.
							return kill(app.processIdentifier, 0) == 0 || errno != ESRCH;
						}]];
					}
					if ([apps count] != 0) {
						NSLog(@"Aborting update attempt because there are %lu running instances of the target app", [apps count]);
						NSDictionary *errorInfo = @{
							NSLocalizedDescriptionKey: NSLocalizedString(@"App Still Running Error", nil),
							NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"All instances of the target application should be quit during the update process", nil),
						};
						return [RACSignal error:[NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorAppStillRunning userInfo:errorInfo]];
					}

					return [[self acquireTargetBundleURLForRequest:renamedRequest] concat:[RACSignal return:renamedRequest]];
				}]
				flattenMap:^(SQRLShipItRequest *targetRequest) {
					if (targetRequest.earlyStaging) {
						return [[self
							installItemToURL:targetRequest.targetBundleURL fromURL:updateBundleURL]
							then:^{
								SQRLInstallerOwnedBundle *ownedBundle = self.ownedBundle;
								NSMutableDictionary *values = [ownedBundle.dictionaryValue mutableCopy];
								values[@keypath(ownedBundle.cleanupURLs)] = @[ targetRequest.updateBundleURL, updateBundleURL, ownedBundle.temporaryURL ];
								NSError *error = nil;
								SQRLInstallerOwnedBundle *committed = [[SQRLInstallerOwnedBundle alloc] initWithDictionary:values error:&error];
								if (committed == nil || ![self saveOwnedBundle:committed error:&error]) return [RACSignal error:error];
								self.preparedRequest = nil;
								self.preparedBundleURL = nil;
								[self setPersistedPreparedBundleURL:nil];
								return [RACSignal return:targetRequest];
							}];
					}

					return [[[[[[self
						installItemToURL:targetRequest.targetBundleURL fromURL:updateBundleURL]
						concat:[RACSignal return:targetRequest.updateBundleURL]]
						concat:[RACSignal return:updateBundleURL]]
						concat:[RACSignal defer:^{
							return [RACSignal return:self.ownedBundle.temporaryURL];
						}]]
						flattenMap:^(NSURL *location) {
							return [[[self
								deleteOwnedBundleAtURL:location]
								doError:^(NSError *error) {
									NSLog(@"Couldn't remove owned bundle at location %@, error %@", location, error.sqrl_verboseDescription);
								}]
								catchTo:[RACSignal empty]];
						}]
						concat:[RACSignal return:targetRequest]];
				}]
				doCompleted:^{
					if (!request.earlyStaging) {
						self.ownedBundle = nil;
					}
				}];
		}]
		sqrl_addTransactionWithName:NSLocalizedString(@"Updating", nil) description:NSLocalizedString(@"%@ is being updated, and interrupting the process could corrupt the application", nil), request.targetBundleURL.path]
		setNameWithFormat:@"%@ -installRequest: %@", self, request];
}

- (RACSignal *)abortInstall {
	// The request may have been tampered with to select a new targetURL to
	// which the moved bundles should be restored.
	//
	// Discard the request parameters and restore the owned bundle to its
	// original location.

	SQRLInstallerOwnedBundle *ownedBundle = self.ownedBundle;
	if (ownedBundle == nil || ownedBundle.cleanupURLs != nil) {
		return [[self discardOrphanedPreparedBundle] then:^{
			return [self cleanupAfterInstallation];
		}];
	}

	return [[[[self
		installItemToURL:ownedBundle.originalURL fromURL:ownedBundle.temporaryURL]
		doCompleted:^{
			self.ownedBundle = nil;
		}]
		sqrl_addTransactionWithName:NSLocalizedString(@"Aborting update", nil) description:NSLocalizedString(@"An update to %@ is being rolled back, and interrupting the process could corrupt the application", nil), ownedBundle.originalURL.path]
		setNameWithFormat:@"%@ -abortInstall", self];
}

- (RACSignal *)cleanupAfterInstallation {
	return [RACSignal defer:^{
		id storedPaths = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)SQRLInstallerPendingCleanupKey, (__bridge CFStringRef)self.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost));
		if (storedPaths != nil && ![storedPaths isKindOfClass:NSArray.class]) {
			return [RACSignal error:[self missingDataErrorWithDescription:NSLocalizedString(@"Invalid pending cleanup state", nil)]];
		}
		NSMutableArray *paths = storedPaths == nil ? [NSMutableArray array] : [storedPaths mutableCopy];
		for (id path in paths) {
			if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) {
				return [RACSignal error:[self missingDataErrorWithDescription:NSLocalizedString(@"Invalid pending cleanup path", nil)]];
			}
		}

		SQRLInstallerOwnedBundle *ownedBundle = self.ownedBundle;
		NSError *error = nil;
		if (ownedBundle.cleanupURLs != nil) {
			for (NSURL *URL in ownedBundle.cleanupURLs) {
				if (![paths containsObject:URL.path]) [paths addObject:URL.path];
			}
			// Persist the independent backlog before clearing rollback state.
			// Failed deletion must not block a later, unrelated update.
			if (![self savePendingCleanupPaths:paths error:&error] || ![self saveOwnedBundle:nil error:&error]) return [RACSignal error:error];
		}

		if (paths.count == 0) return [RACSignal empty];

		NSArray *pendingPaths = [paths copy];
		__block NSError *firstDeleteError = nil;
		RACSignal *cleanupSignal = [RACSignal empty];
		for (NSString *path in pendingPaths) {
			cleanupSignal = [cleanupSignal concat:[RACSignal defer:^{
				return [[[self
					deleteOwnedBundleAtURL:[NSURL fileURLWithPath:path]]
					then:^{
						[paths removeObject:path];
						NSError *saveError = nil;
						if (![self savePendingCleanupPaths:paths error:&saveError]) return [RACSignal error:saveError];
						return [RACSignal empty];
					}]
					catch:^(NSError *deleteError) {
						if (firstDeleteError == nil) firstDeleteError = deleteError;
						return [RACSignal empty];
					}];
			}]];
		}
		return [cleanupSignal then:^{
			return firstDeleteError == nil ? [RACSignal empty] : [RACSignal error:firstDeleteError];
		}];
	}];
}

- (BOOL)savePendingCleanupPaths:(NSArray *)paths error:(NSError **)error {
	CFPreferencesSetValue((__bridge CFStringRef)SQRLInstallerPendingCleanupKey, paths.count == 0 ? NULL : (__bridge CFArrayRef)paths, (__bridge CFStringRef)self.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
	if (CFPreferencesSynchronize((__bridge CFStringRef)self.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)) return YES;
	if (error != NULL) {
		*error = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerErrorInvalidState userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not persist pending cleanup", nil) }];
	}
	return NO;
}

#pragma mark Bundle Ownership

- (RACSignal *)ownedTemporaryDirectoryURL {
	return [[[RACSignal
		defer:^{
			NSString *tmpPath = [NSTemporaryDirectory() stringByResolvingSymlinksInPath];
			NSString *template = [NSString stringWithFormat:@"%@.XXXXXXXX", self.applicationIdentifier];

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
		setNameWithFormat:@"%@ -ownedDirectoryURL", self];
}

- (RACSignal *)copyBundleAtURL:(NSURL *)bundleURL toDirectory:(NSURL *)directoryURL {
	return [self copyBundleAtURL:bundleURL toDirectory:directoryURL useClone:NO];
}

- (RACSignal *)copyBundleAtURL:(NSURL *)bundleURL toDirectory:(NSURL *)directoryURL useClone:(BOOL)useClone {
	NSParameterAssert(bundleURL != nil);
	NSParameterAssert(directoryURL != nil);

	NSURL *newBundleURL = [directoryURL URLByAppendingPathComponent:bundleURL.lastPathComponent];

	return [[[RACSignal
		defer:^{
			if (useClone) {
				// COPYFILE_CLONE uses COW where supported and falls back to copying
				// elsewhere. Omit COPYFILE_ACL so copyfile does not pass CLONE_ACL
				// (or copy ACLs on fallback), and strip any remaining ACLs in
				// -takeOwnershipOfDirectory:stripACLs: if NSFileManager is used.
				if (copyfile(bundleURL.fileSystemRepresentation, newBundleURL.fileSystemRepresentation, NULL,
					COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL | COPYFILE_CLONE) == 0) {
					return [RACSignal return:newBundleURL];
				}
				int code = errno;
				NSLog(@"Clone/copy failed for %@: %s", bundleURL, strerror(code));
				NSError *error = nil;
				if ([NSFileManager.defaultManager fileExistsAtPath:newBundleURL.path] &&
					![NSFileManager.defaultManager removeItemAtURL:newBundleURL error:&error]) return [RACSignal error:error];
			}
			NSError *error = nil;
			BOOL copy = [NSFileManager.defaultManager copyItemAtURL:bundleURL toURL:newBundleURL error:&error];
			if (!copy) return [RACSignal error:error];

			return [RACSignal return:newBundleURL];
		}]
		catch:^(NSError *error) {
			NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Failed to copy bundle %@ to directory %@", nil), bundleURL, newBundleURL];
			return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorBackupFailed toError:error]];
		}]
		setNameWithFormat:@"%@ -copyBundleAtURL: %@ toDirectory: %@", self, bundleURL, directoryURL];
}

- (RACSignal *)deleteOwnedBundleAtURL:(NSURL *)bundleURL {
	NSParameterAssert(bundleURL != nil);

	return [[[RACSignal
		defer:^{
			NSError *error;
			if ([NSFileManager.defaultManager removeItemAtURL:bundleURL error:&error]) {
				return [RACSignal empty];
			} else if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileNoSuchFileError) {
				// The bundle was already moved into place by installItemToURL:;
				// proceed so the parent mkdtemp directory still gets removed.
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
			if (rmdir(temporaryDirectoryURL.path.fileSystemRepresentation) == 0 || errno == ENOENT) {
				return [RACSignal empty];
			} else {
				int code = errno;
				NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];

				const char *desc = strerror(code);
				if (desc != NULL) {
					userInfo[NSLocalizedDescriptionKey] = @(desc);
				} else {
					userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Unknown POSIX error", @"");
				}

				userInfo[NSLocalizedFailureReasonErrorKey] = [NSString stringWithFormat:NSLocalizedString(@"Couldn't remove temp dir \"%@\"", @""), temporaryDirectoryURL.path];
				userInfo[NSURLErrorKey] = temporaryDirectoryURL;

				return [RACSignal error:[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:userInfo]];
			}
		}]
		setNameWithFormat:@"%@ -deleteOwnedBundleAtURL: %@", self, bundleURL];
}

#pragma mark Verification

- (RACSignal *)codeSignatureForBundleAtURL:(NSURL *)URL {
	return [[RACSignal
		defer:^{
			NSError *error;
			SQRLCodeSignature *codeSignature = [SQRLCodeSignature signatureWithBundle:URL error:&error];
			if (codeSignature == nil) return [RACSignal error:error];
			return [RACSignal return:codeSignature];
		}]
		setNameWithFormat:@"%@ -codeSignatureForBundleAtURL: %@", self, URL];
}

- (RACSignal *)verifyBundleAtURL:(NSURL *)bundleURL usingSignature:(SQRLCodeSignature *)signature {
	NSParameterAssert(bundleURL != nil);
	NSParameterAssert(signature != nil);

	return [[[self
		takeOwnershipOfDirectory:bundleURL]
		then:^{
			return [signature verifyBundleAtURL:bundleURL];
		}]
		setNameWithFormat:@"%@ -verifyBundleAtURL: %@ usingSignature: %@", self, bundleURL, signature];
}

#pragma mark Installation

/// Check if the target should be renamed and provide the renamed URL.
///
/// targetURL - The URL for the target. Cannot be nil.
/// sourceURL - The URL for the source. Cannot be nil.
///
/// Returns a signal which will send the URL for the renamed target. If a rename
/// isn't needed then it will send `targetURL`.
- (RACSignal *)renamedTargetIfNeededWithTargetURL:(NSURL *)targetURL sourceURL:(NSURL *)sourceURL {
	return [RACSignal defer:^{
		NSBundle *sourceBundle = [NSBundle bundleWithURL:sourceURL];
		NSString *targetExecutableName = targetURL.lastPathComponent.stringByDeletingPathExtension;
		NSString *sourceExecutableName = sourceBundle.sqrl_executableName;

		// If they're already the same then we're good.
		if ([targetExecutableName isEqual:sourceExecutableName]) {
			return [RACSignal return:targetURL];
		}

		NSString *newAppName = [sourceExecutableName stringByAppendingPathExtension:@"app"];
		NSURL *newTargetURL = [targetURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:newAppName];

		// If there's already something there then don't rename to it.
		if ([NSFileManager.defaultManager fileExistsAtPath:newTargetURL.path]) {
			return [RACSignal return:targetURL];
		}

		return [RACSignal return:newTargetURL];
	}];
}

- (RACSignal *)installItemToURL:(NSURL *)targetURL fromURL:(NSURL *)sourceURL {
	NSParameterAssert(targetURL != nil);
	NSParameterAssert(sourceURL != nil);

	NSLog(@"Moving bundle from %@ to %@", sourceURL, targetURL);

	// If both the sourceURL and the targetURL exist we can try to skip a permissions check
	// by moving Thing.app/Contents directly.  This allows us to update applications without
	// permission to write files into the parent directory of Thing.app
	//
	// There is no known case where these directories don't exist but in order to handle
	// edge cases / race conditions we'll handle it anyway.
	//
	// This exists check is non-atomic with the rename call below but that's OK
	BOOL canRenameContentsDirectly = FALSE;
	// For now while this is tested at scale this new option is behind a user default, this
	// can be set by applications wishing to test this feature at runtime.  If it causes issues
	// it can be opted out by individual users by setting this key to false explicitly.
	// Once this has bene tested at scale it will become the default for all Squirrel.Mac
	// users.
	NSUserDefaults *defaults = [[NSUserDefaults alloc] init];
	[defaults addSuiteNamed:_applicationIdentifier];
	// In cases where this code is being executed under the ShipIt executable it's running
	// under an application identifier equal to {parent_identifier}.ShipIt
	// In this case we need to use the true parent identifier too as that is 99% of the time
	// where the key will be set.
	if ([_applicationIdentifier hasSuffix:@".ShipIt"]) {
		[defaults addSuiteNamed:[_applicationIdentifier substringToIndex:[_applicationIdentifier length] - 7]];
	}

	if ([defaults boolForKey:@"SquirrelMacEnableDirectContentsWrite"]) {
		canRenameContentsDirectly = [NSFileManager.defaultManager fileExistsAtPath:targetURL.path] && [NSFileManager.defaultManager fileExistsAtPath:sourceURL.path];

		if (canRenameContentsDirectly) {
			NSLog(@"Moving bundles via 'Contents' folder rename");
		} else {
			NSLog(@"Moving bundles directly as one of source / target does not exist.  This is unexpected.");
		}
	} else {
		NSLog(@"Moving bundles directly as SquirrelMacEnableDirectContentsWrite is disabled for app: %@", _applicationIdentifier);
	}
	NSURL *targetContentsURL = canRenameContentsDirectly ? [targetURL URLByAppendingPathComponent:@"Contents"] : targetURL;
	NSURL *sourceContentsURL = canRenameContentsDirectly ? [sourceURL URLByAppendingPathComponent:@"Contents"] : sourceURL;

	return [[[[RACSignal
		defer:^{
			// rename() is atomic, NSFileManager sucks.
			if (rename(sourceContentsURL.path.fileSystemRepresentation, targetContentsURL.path.fileSystemRepresentation) == 0) {
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
			NSLog(@"Moved bundle contents from %@ to %@", sourceContentsURL, targetContentsURL);
		}]
		catch:^(NSError *error) {
			if (![error.domain isEqual:NSPOSIXErrorDomain] || error.code != EXDEV) return [RACSignal error:error];

			// If the locations lie on two different volumes, remove the
			// destination by hand, then perform a move.
			[NSFileManager.defaultManager removeItemAtURL:targetContentsURL error:NULL];

			if ([NSFileManager.defaultManager moveItemAtURL:sourceContentsURL toURL:targetContentsURL error:&error]) {
				NSLog(@"Moved bundle contents across volumes from %@ to %@", sourceContentsURL, targetContentsURL);
				return [RACSignal empty];
			} else {
				NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Couldn't move bundle contents %@ across volumes to %@", nil), sourceContentsURL, targetContentsURL];
				return [RACSignal error:[self errorByAddingDescription:description code:SQRLInstallerErrorMovingAcrossVolumes toError:error]];
			}
		}]
		setNameWithFormat:@"%@ -installItemAtURL: %@ fromURL: %@", self, targetContentsURL, sourceContentsURL];
}

#pragma mark Quarantine Bit Removal

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
					if (desc != NULL) {
						userInfo[NSLocalizedDescriptionKey] = @(desc);
					} else {
						userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Unknown POSIX error", @"");
					}

					userInfo[NSLocalizedFailureReasonErrorKey] = [NSString stringWithFormat:NSLocalizedString(@"Couldn't remove quarantine attribute from \"%@\". This most likely means the file is read-only.", @""), URL.path];
					userInfo[NSURLErrorKey] = URL;

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
	return [self takeOwnershipOfDirectory:directoryURL stripACLs:NO];
}

- (RACSignal *)takeOwnershipOfDirectory:(NSURL *)directoryURL stripACLs:(BOOL)stripACLs {
	NSParameterAssert(directoryURL != nil);

	return [[[RACSignal
		createSignal:^(id<RACSubscriber> subscriber) {
			NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:directoryURL includingPropertiesForKeys:@[ NSURLFileSecurityKey ] options:0 errorHandler:^ BOOL (NSURL *url, NSError *error) {
				[subscriber sendError:error];
				return NO;
			}];

			return [[enumerator.rac_sequence.signal
				startWith:directoryURL]
				subscribe:subscriber];
		}]
		flattenMap:^(NSURL *itemURL) {
			return [[[self
				readFileSecurityOfURL:itemURL]
				flattenMap:^(NSFileSecurity *fileSecurity) {
					if (![self takeOwnershipOfFileSecurity:fileSecurity stripACLs:stripACLs]) {
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

- (BOOL)takeOwnershipOfFileSecurity:(NSFileSecurity *)fileSecurity stripACLs:(BOOL)stripACLs {
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

	if (!CFFileSecuritySetMode(actualFileSecurity, fileMode)) return NO;

	if (stripACLs) {
		// Pass kCFFileSecurityRemoveACL so chmodx_np deletes any extended ACL
		// on disk (e.g. when copyBundleAtURL: falls back to NSFileManager).
		// Passing NULL or CFFileSecurityClearProperties only clears FS_VALID_ACL
		// on the in-memory filesec_t and leaves existing on-disk ACLs intact.
		if (!CFFileSecuritySetAccessControlList(actualFileSecurity, kCFFileSecurityRemoveACL)) return NO;
	}

	return YES;
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
