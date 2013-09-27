//
//  SQRLUpdater.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdater.h"

#import "EXTKeyPathCoding.h"

#import "NSError+SQRLVerbosityExtensions.h"
#import "NSProcessInfo+SQRLVersionExtensions.h"
#import "SQRLArguments.h"
#import "SQRLCodeSignatureVerifier.h"
#import "SQRLShipItLauncher.h"
#import "SQRLUpdate.h"
#import "SQRLUpdate+Private.h"
#import "SQRLUpdateOperation.h"

NSString * const SQRLUpdaterUpdateAvailableNotification = @"SQRLUpdaterUpdateAvailableNotification";
NSString * const SQRLUpdaterUpdateAvailableNotificationUpdateKey = @"SQRLUpdaterUpdateAvailableNotificationUpdateKey";

NSString * const SQRLUpdaterErrorDomain = @"SQRLUpdaterErrorDomain";
const NSInteger SQRLUpdaterErrorNoUpdateWaiting = 1;
const NSInteger SQRLUpdaterErrorPreparingUpdateJob = 2;
const NSInteger SQRLUpdaterErrorRetrievingCodeSigningRequirement = 3;

@interface SQRLUpdater () <NSURLConnectionDataDelegate>
// A serial operation queue for update checks.
@property (nonatomic, strong, readonly) NSOperationQueue *updateQueue;

// A timer used to poll for updates.
@property (nonatomic, strong) NSTimer *updateTimer;

// Current update operation, non nil when update check/download in progress.
@property (nonatomic, strong) SQRLUpdateOperation *updateOperation;

// Pending update, pulled from updateOperation.
@property (nonatomic, strong) SQRLUpdate *update;

// The verifier used to check code against the running application's signature.
@property (nonatomic, strong, readonly) SQRLCodeSignatureVerifier *verifier;

@end

@implementation SQRLUpdater

#pragma mark KVO

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key {
	NSMutableSet *keyPaths = [[super keyPathsForValuesAffectingValueForKey:key] mutableCopy];

	if ([key isEqualToString:@keypath(SQRLUpdater.new, state)]) {
		[keyPaths addObject:[@[ @keypath(SQRLUpdater.new, updateOperation), @keypath(SQRLUpdateOperation.new, state) ] componentsJoinedByString:@"."]];
		[keyPaths addObject:@keypath(SQRLUpdater.new, update)];
	}

	return keyPaths;
}

#pragma mark Lifecycle

- (id)init {
	NSAssert(NO, @"Use -initWithUpdateRequest: instead");
	return nil;
}

- (id)initWithUpdateRequest:(NSURLRequest *)updateRequest {
	NSParameterAssert(updateRequest != nil);

	self = [super init];
	if (self == nil) return nil;

	_updateRequest = [updateRequest copy];
	
	_updateQueue = [[NSOperationQueue alloc] init];
	self.updateQueue.maxConcurrentOperationCount = 1;
	self.updateQueue.name = @"com.github.Squirrel.updateCheckingQueue";

	_verifier = [[SQRLCodeSignatureVerifier alloc] init];
	if (_verifier == nil) return nil;
	
	return self;
}

- (void)dealloc {
	[_updateTimer invalidate];
}

#pragma mark Properties

- (SQRLUpdaterState)state {
	if (self.updateOperation != nil) return self.updateOperation.state;
	if (self.update != nil) return SQRLUpdaterStateAwaitingRelaunch;
	return SQRLUpdaterStateIdle;
}

#pragma mark Update Timer

- (void)setUpdateTimer:(NSTimer *)updateTimer {
	if (_updateTimer == updateTimer) return;

	[_updateTimer invalidate];
	_updateTimer = updateTimer;
}

- (void)startAutomaticChecksWithInterval:(NSTimeInterval)interval {
	dispatch_async(dispatch_get_main_queue(), ^{
		self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(checkForUpdates) userInfo:nil repeats:YES];
	});
}

#pragma mark Checking for Updates

- (void)checkForUpdates {
	NSParameterAssert(self.updateRequest != nil);

	if (getenv("DISABLE_UPDATE_CHECK") != NULL) return;

	if (self.state != SQRLUpdaterStateIdle) return; // Ongoing update

	SQRLUpdateOperation *updateOperation = [[SQRLUpdateOperation alloc] initWithUpdateRequest:self.updateRequest verifier:self.verifier];
	[self.updateQueue addOperation:updateOperation];
	self.updateOperation = updateOperation;

	NSOperation *finishOperation = [NSBlockOperation blockOperationWithBlock:^ {
		NSError *updateError = nil;
		SQRLUpdate *update = updateOperation.completionProvider(&updateError);
		if (update == nil) {
			[self logUpdateError:updateError];
			return;
		}

		[self announceUpdate:update];
	}];
	[finishOperation addDependency:updateOperation];
	[NSOperationQueue.mainQueue addOperation:finishOperation];

	NSOperation *idleOperation = [NSBlockOperation blockOperationWithBlock:^{
		self.updateOperation = nil;
	}];
	[idleOperation addDependency:finishOperation];
	[NSOperationQueue.mainQueue addOperation:idleOperation];
}

- (void)logUpdateError:(NSError *)error {
	NSLog(@"Error checking for updates: %@", error.sqrl_verboseDescription);
}

- (void)announceUpdate:(SQRLUpdate *)update {
	NSDictionary *notificationInfo = @{
		SQRLUpdaterUpdateAvailableNotificationUpdateKey: update,
	};
	[NSNotificationCenter.defaultCenter postNotificationName:SQRLUpdaterUpdateAvailableNotification object:self userInfo:notificationInfo];

	self.update = update;
}

- (void)finishAndSetIdle {
	self.shouldRelaunch = NO;
}

#pragma mark Installing Updates

- (void)installUpdateIfNeeded:(void (^)(BOOL success, NSError *error))completionHandler {
	__typeof__(completionHandler) originalHandler = [completionHandler copy];

	completionHandler = ^(BOOL success, NSError *error) {
		if (!success) [self finishAndSetIdle];
		originalHandler(success, error);
	};

	SQRLUpdate *update = self.update;
	if (update == nil) {
		NSDictionary *userInfo = @{
			NSLocalizedDescriptionKey: NSLocalizedString(@"No update to install", nil),
		};

		completionHandler(NO, [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorNoUpdateWaiting userInfo:userInfo]);
		return;
	}

	NSRunningApplication *currentApplication = NSRunningApplication.currentApplication;
	NSURL *targetURL = currentApplication.bundleURL;

	NSData *requirementData = self.verifier.requirementData;
	if (requirementData == nil) {
		NSDictionary *userInfo = @{
			NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not load code signing requirement for %@", nil), currentApplication.bundleIdentifier],
		};

		completionHandler(NO, [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorRetrievingCodeSigningRequirement userInfo:userInfo]);
		return;
	}

	// If we can't determine whether it can be written, assume nonprivileged and
	// wait for another more canonical error
	NSNumber *targetWritable = nil;
	NSError *targetWritableError = nil;
	BOOL getWritable = [targetURL getResourceValue:&targetWritable forKey:NSURLIsWritableKey error:&targetWritableError];

	NSError *error = nil;
	xpc_connection_t connection = [SQRLShipItLauncher launchPrivileged:(getWritable && !targetWritable.boolValue) error:&error];
	if (connection == NULL) {
		completionHandler(NO, error);
		return;
	}
	
	[NSProcessInfo.processInfo disableSuddenTermination];

	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	@onExit {
		xpc_release(message);
	};

	xpc_dictionary_set_string(message, SQRLShipItCommandKey, SQRLShipItInstallCommand);
	xpc_dictionary_set_string(message, SQRLTargetBundleURLKey, targetURL.absoluteString.UTF8String);
	xpc_dictionary_set_string(message, SQRLUpdateBundleURLKey, update.downloadedUpdateURL.absoluteString.UTF8String);
	xpc_dictionary_set_bool(message, SQRLShouldRelaunchKey, self.shouldRelaunch);
	xpc_dictionary_set_bool(message, SQRLWaitForConnectionKey, true);
	xpc_dictionary_set_data(message, SQRLCodeSigningRequirementKey, requirementData.bytes, requirementData.length);

	xpc_connection_resume(connection);
	xpc_connection_send_message_with_reply(connection, message, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(xpc_object_t reply) {
		BOOL success = xpc_dictionary_get_bool(reply, SQRLShipItSuccessKey);
		NSError *error = nil;
		if (!success) {
			const char *errorStr = xpc_dictionary_get_string(reply, SQRLShipItErrorKey);
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: @(errorStr) ?: NSLocalizedString(@"An unknown error occurred within ShipIt", nil),
			};

			error = [NSError errorWithDomain:SQRLUpdaterErrorDomain code:SQRLUpdaterErrorPreparingUpdateJob userInfo:userInfo];
			[NSProcessInfo.processInfo enableSuddenTermination];
		}

		completionHandler(success, error);
	});
}

@end
