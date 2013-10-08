//
//  main.m
//  shipit
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import "NSError+SQRLVerbosityExtensions.h"
#import "RACSignal+SQRLTransactionExtensions.h"
#import "SQRLArguments.h"
#import "SQRLInstaller.h"
#import "SQRLStateManager.h"
#import "SQRLTerminationListener.h"
#import "SQRLXPCConnection.h"
#import "SQRLXPCObject.h"

// The maximum number of times ShipIt should run the same installation state, in
// an attempt to update.
//
// If ShipIt is launched in the same state more than this number of times,
// updating will abort.
static const NSUInteger SQRLShipItMaximumInstallationAttempts = 3;

// The domain for errors generated here.
static NSString * const SQRLShipItErrorDomain = @"SQRLShipItErrorDomain";

// A key required for a command was not provided.
static const NSInteger SQRLShipItErrorRequiredKeyMissing = 1;

// The application terminated while we were still setting up. If installation
// continued, it could be subject to race conditions.
static const NSInteger SQRLShipItErrorApplicationTerminatedTooEarly = 2;

// The state manager for this job.
//
// Set immediately upon startup.
static SQRLStateManager *stateManager = nil;

// The shared installer for this job.
//
// Set immediately upon startup.
static SQRLInstaller *sharedInstaller = nil;

// Waits for all instances of the target application (as described in the
// `stateManager`) to exit, then sends completed.
static RACSignal *waitForTerminationIfNecessary(void) {
	return [[RACSignal
		defer:^{
			if (stateManager.waitForBundleIdentifier == nil) return [RACSignal empty];

			SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithURL:stateManager.targetBundleURL bundleIdentifier:stateManager.waitForBundleIdentifier];
			return [listener waitForTermination];
		}]
		setNameWithFormat:@"waitForTerminationIfNecessary"];
}

// Resumes an installation that was started on a previous run.
static void resumeInstallation(void) {
	RACSignal *termination = waitForTerminationIfNecessary();

	if (++stateManager.installationStateAttempt > SQRLShipItMaximumInstallationAttempts) {
		NSLog(@"Too many attempts to install from state %i, aborting update", (int)stateManager.state);

		[[[termination
			then:^{
				return [sharedInstaller.abortInstallationCommand execute:nil];
			}]
			catch:^(NSError *error) {
				NSLog(@"Error aborting installation: %@", error);
				return [RACSignal empty];
			}]
			subscribeCompleted:^{
				exit(EXIT_SUCCESS);
			}];
	} else {
		[[termination
			then:^{
				return [[sharedInstaller.installUpdateCommand
					execute:nil]
					initially:^{
						NSLog(@"Resuming installation from state %i", (int)stateManager.state);
					}];
			}]
			subscribeError:^(NSError *error) {
				NSLog(@"Installation error: %@", error);
				exit(EXIT_FAILURE);
			} completed:^{
				NSLog(@"Installation completed successfully");
				exit(EXIT_SUCCESS);
			}];
	}
}

// Starts installation based on the information in the given XPC event.
static RACSignal *installWithArgumentsFromEvent(SQRLXPCObject *event) {
	return [[RACSignal createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
		SQRLXPCObject *reply = [[SQRLXPCObject alloc] initWithXPCObject:xpc_dictionary_create_reply(event.object)];

		SQRLXPCConnection *remoteConnection = nil;
		if (reply != nil) remoteConnection = [[SQRLXPCConnection alloc] initWithXPCObject:xpc_dictionary_get_remote_connection(reply.object)];

		size_t requirementDataLen = 0;
		const void *requirementDataPtr = xpc_dictionary_get_data(event.object, SQRLCodeSigningRequirementKey, &requirementDataLen);

		NSURL *targetBundleURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event.object, SQRLTargetBundleURLKey))] filePathURL];
		NSURL *updateBundleURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event.object, SQRLUpdateBundleURLKey))] filePathURL];

		if (targetBundleURL == nil || updateBundleURL == nil || requirementDataPtr == NULL) {
			[subscriber sendError:[NSError errorWithDomain:SQRLShipItErrorDomain code:SQRLShipItErrorRequiredKeyMissing userInfo:@{ NSLocalizedDescriptionKey: @"Required key not provided" }]];
			return nil;
		}

		const char *waitForIdentifier = xpc_dictionary_get_string(event.object, SQRLWaitForBundleIdentifierKey);

		stateManager.targetBundleURL = targetBundleURL;
		stateManager.updateBundleURL = updateBundleURL;
		stateManager.requirementData = [NSData dataWithBytes:requirementDataPtr length:requirementDataLen];
		stateManager.relaunchAfterInstallation = xpc_dictionary_get_bool(event.object, SQRLShouldRelaunchKey);
		stateManager.waitForBundleIdentifier = (waitForIdentifier == NULL ? nil : @(waitForIdentifier));
		stateManager.state = SQRLShipItStateClearingQuarantine;

		RACMulticastConnection *terminationConnection = [[waitForTerminationIfNecessary()
			logAll]
			multicast:[RACReplaySubject subject]];

		RACSignal *notification = [RACSignal empty];
		if (remoteConnection != nil) {
			RACSignal *errorSignal = [RACSignal error:[NSError errorWithDomain:SQRLShipItErrorDomain code:SQRLShipItErrorApplicationTerminatedTooEarly userInfo:@{ NSLocalizedDescriptionKey: @"Application PID could not be found" }]];

			RACSignal *termination = [RACSignal empty];
			if (waitForIdentifier != NULL) {
				termination = [[[terminationConnection.signal
					filter:^ BOOL (NSRunningApplication *app) {
						return app.processIdentifier == xpc_connection_get_pid(remoteConnection.object);
					}]
					concat:errorSignal]
					// This avoids the error if we find an app that matches our
					// condition above.
					take:1];
			}
			
			notification = [[[[termination
				doCompleted:^{
					xpc_dictionary_set_bool(reply.object, SQRLReplySuccessKey, true);
				}]
				catch:^(NSError *terminationError) {
					xpc_dictionary_set_bool(reply.object, SQRLReplySuccessKey, false);
					xpc_dictionary_set_string(reply.object, SQRLReplyErrorKey, terminationError.localizedDescription.UTF8String ?: "Error setting up termination listening");
					return [RACSignal empty];
				}]
				then:^{
					// Tell the remote connection whether setup succeeded or
					// failed, and wait for them to sign off on it too.
					return [[remoteConnection sendMessageExpectingReply:reply] ignoreValues];
				}]
				catch:^(NSError *error) {
					if ([error.domain isEqual:SQRLXPCErrorDomain] && (error.code == SQRLXPCErrorConnectionInvalid || error.code == SQRLXPCErrorConnectionInterrupted)) {
						// The remote process terminated before we could send
						// our reply.
						NSDictionary *userInfo = @{
							NSLocalizedDescriptionKey: @"Application terminated before setup finished",
							NSUnderlyingErrorKey: error
						};

						return [RACSignal error:[NSError errorWithDomain:SQRLShipItErrorDomain code:SQRLShipItErrorApplicationTerminatedTooEarly userInfo:userInfo]];
					}

					return [RACSignal empty];
				}];
		}

		RACDisposable *installationDisposable = [[[RACSignal
			merge:@[
				terminationConnection.signal,
				notification
			]]
			then:^{
				return [[[[sharedInstaller.installUpdateCommand
					execute:nil]
					initially:^{
						NSLog(@"Beginning installation");
					}]
					doCompleted:^{
						NSLog(@"Installation completed successfully");
					}]
					doError:^(NSError *error) {
						NSLog(@"Installation error: %@", error);
					}];
			}]
			subscribe:subscriber];

		RACDisposable *terminationDisposable = [terminationConnection connect];
		return [RACDisposable disposableWithBlock:^{
			[terminationDisposable dispose];
			[installationDisposable dispose];
		}];
	}] setNameWithFormat:@"installWithArgumentsFromEvent(%@)", event];
}

static RACSignal *handleEvent(SQRLXPCObject *event) {
	const char *command = xpc_dictionary_get_string(event.object, SQRLShipItCommandKey);
	if (strcmp(command, SQRLShipItInstallCommand) != 0) return [RACSignal empty];

	return [[[[installWithArgumentsFromEvent(event) logAll]
		doError:^(NSError *error) {
			exit(EXIT_FAILURE);
		}]
		doCompleted:^{
			exit(EXIT_SUCCESS);
		}]
		setNameWithFormat:@"handleEvent %@", event];
}

static RACSignal *handleClient(SQRLXPCConnection *client) {
	return [[[[[[[[[[client
		autoconnect]
		setNameWithFormat:@"client"]
		logAll]
		deliverOn:[RACScheduler schedulerWithPriority:RACSchedulerPriorityHigh]]
		catch:^(NSError *error) {
			NSLog(@"XPC error from client: %@", error);
			return [RACSignal empty];
		}]
		filter:^ BOOL (SQRLXPCObject *event) {
			return xpc_get_type(event.object) == XPC_TYPE_DICTIONARY;
		}]
		map:^(SQRLXPCObject *event) {
			return [handleEvent(event) sqrl_addSubscriptionTransactionWithName:NSLocalizedString(@"Preparing update", nil) description:NSLocalizedString(@"An update is being prepared. Interrupting the process could corrupt the application.", nil)];
		}]
		switchToLatest]
		logAll]
		setNameWithFormat:@"handleClient %@", client];
}

static void handleService(SQRLXPCConnection *service) {
	[[[[[[[[[[service
		autoconnect]
		setNameWithFormat:@"service"]
		logAll]
		deliverOn:[RACScheduler schedulerWithPriority:RACSchedulerPriorityHigh]]
		catch:^(NSError *error) {
			NSLog(@"XPC error from service: %@", error);
			return [RACSignal empty];
		}]
		map:^(SQRLXPCObject *event) {
			return [[SQRLXPCConnection alloc] initWithXPCObject:event.object];
		}]
		map:^(SQRLXPCConnection *client) {
			return handleClient(client);
		}]
		switchToLatest]
		logAll]
		subscribeCompleted:^{
			exit(EXIT_SUCCESS);
		}];
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		atexit_b(^{
			NSLog(@"ShipIt quitting");
		});

		if (argc < 2) {
			NSLog(@"Missing Mach service label for ShipIt");
			return EXIT_FAILURE;
		}

		const char *serviceName = argv[1];

		stateManager = [[SQRLStateManager alloc] initWithIdentifier:@(serviceName)];
		sharedInstaller = [[SQRLInstaller alloc] initWithStateManager:stateManager];

		if (stateManager.state != SQRLShipItStateNothingToDo) {
			resumeInstallation();
		} else {
			xpc_connection_t service = xpc_connection_create_mach_service(serviceName, NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
			if (service == NULL) {
				NSLog(@"Could not start Mach service \"%s\"", serviceName);
				exit(EXIT_FAILURE);
			}

			NSLog(@"ShipIt started with Mach service name \"%s\"", serviceName);

			@onExit {
				xpc_release(service);
			};

			handleService([[SQRLXPCConnection alloc] initWithXPCObject:service]);
		}

		dispatch_main();
	}

	return EXIT_SUCCESS;
}

