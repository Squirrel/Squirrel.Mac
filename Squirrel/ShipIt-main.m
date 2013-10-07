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

// Resumes an installation that was started on a previous run.
static void resumeInstallation(void) {
	if (++stateManager.installationStateAttempt > SQRLShipItMaximumInstallationAttempts) {
		NSLog(@"Too many attempts to install from state %i, aborting update", (int)stateManager.state);

		[[[sharedInstaller.abortInstallationCommand
			execute:nil]
			catch:^(NSError *error) {
				NSLog(@"Error aborting installation: %@", error);
				return [RACSignal empty];
			}]
			subscribeCompleted:^{
				exit(EXIT_SUCCESS);
			}];
	} else {
		[[[sharedInstaller.installUpdateCommand
			execute:nil]
			initially:^{
				NSLog(@"Resuming installation from state %i", (int)stateManager.state);
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
	SQRLXPCObject *reply = [[SQRLXPCObject alloc] initWithXPCObject:xpc_dictionary_create_reply(event.object)];

	SQRLXPCConnection *remoteConnection = nil;
	if (reply != nil) remoteConnection = [[SQRLXPCConnection alloc] initWithXPCObject:xpc_dictionary_get_remote_connection(reply.object)];

	RACSignal *errorSignal = [RACSignal error:[NSError errorWithDomain:SQRLShipItErrorDomain code:SQRLShipItErrorApplicationTerminatedTooEarly userInfo:@{ NSLocalizedDescriptionKey: @"Application terminated before setup finished" }]];

	return [[RACSignal createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
		size_t requirementDataLen = 0;
		const void *requirementDataPtr = xpc_dictionary_get_data(event.object, SQRLCodeSigningRequirementKey, &requirementDataLen);

		NSURL *targetBundleURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event.object, SQRLTargetBundleURLKey))] filePathURL];
		NSURL *updateBundleURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event.object, SQRLUpdateBundleURLKey))] filePathURL];

		if (targetBundleURL == nil || updateBundleURL == nil || requirementDataPtr == NULL) {
			[subscriber sendError:[NSError errorWithDomain:SQRLShipItErrorDomain code:SQRLShipItErrorRequiredKeyMissing userInfo:@{ NSLocalizedDescriptionKey: @"Required key not provided" }]];
			return nil;
		}

		stateManager.targetBundleURL = targetBundleURL;
		stateManager.updateBundleURL = updateBundleURL;
		stateManager.requirementData = [NSData dataWithBytes:requirementDataPtr length:requirementDataLen];
		stateManager.relaunchAfterInstallation = xpc_dictionary_get_bool(event.object, SQRLShouldRelaunchKey);
		stateManager.state = SQRLShipItStateClearingQuarantine;

		RACSignal *termination = [RACSignal empty];
		const char *waitForIdentifier = xpc_dictionary_get_string(event.object, SQRLWaitForBundleIdentifierKey);
		if (waitForIdentifier != NULL) {
			SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithURL:targetBundleURL bundleIdentifier:@(waitForIdentifier)];
			termination = [listener waitForTermination];

			if (remoteConnection != nil) {
				termination = [[[termination
					skipUntilBlock:^ BOOL (NSRunningApplication *app) {
						return app.processIdentifier == xpc_connection_get_pid(remoteConnection.object);
					}]
					concat:errorSignal]
					// This avoids the error if we find an app that matches our
					// condition above.
					take:1];
			}
		}

		RACMulticastConnection *terminationConnection = [[termination
			ignoreValues]
			multicast:[RACReplaySubject subject]];

		// Use only while synchronized on `terminationConnection`.
		__block BOOL receivedTerminationError = NO;
		__block NSError *terminationError = nil;

		[terminationConnection.signal subscribeError:^(NSError *error) {
			@synchronized (terminationConnection) {
				receivedTerminationError = YES;
				terminationError = error;
			}

			[subscriber sendError:error];
		}];

		// After connecting here, we'll know whether we're successfully waiting
		// for termination.
		RACDisposable *terminationDisposable = [terminationConnection connect];

		RACSignal *notification = [RACSignal empty];
		if (remoteConnection != nil) {
			// Notify the remote connection about whether setup succeeded or failed.
			@synchronized (terminationConnection) {
				if (receivedTerminationError) {
					xpc_dictionary_set_bool(reply.object, SQRLShipItSuccessKey, false);
					xpc_dictionary_set_string(reply.object, SQRLShipItErrorKey, terminationError.localizedDescription.UTF8String ?: "Error setting up termination listening");
				} else {
					xpc_dictionary_set_bool(reply.object, SQRLShipItSuccessKey, true);
				}
			}

			notification = [[[remoteConnection
				sendMessageExpectingReply:reply]
				ignoreValues]
				catch:^(NSError *error) {
					if ([error.domain isEqual:SQRLXPCErrorDomain] && error.code == SQRLXPCErrorConnectionInvalid) {
						// The remote process terminated before we could send
						// our reply.
						return errorSignal;
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

		return [RACDisposable disposableWithBlock:^{
			[terminationDisposable dispose];
			[installationDisposable dispose];
		}];
	}] setNameWithFormat:@"installWithArgumentsFromEvent(%@)", event];
}

static RACSignal *handleEvent(SQRLXPCObject *event, SQRLXPCConnection *client) {
	const char *command = xpc_dictionary_get_string(event.object, SQRLShipItCommandKey);
	if (strcmp(command, SQRLShipItInstallCommand) != 0) return [RACSignal empty];

	return [[[installWithArgumentsFromEvent(event)
		doError:^(NSError *error) {
			exit(EXIT_FAILURE);
		}]
		doCompleted:^{
			exit(EXIT_SUCCESS);
		}]
		setNameWithFormat:@"handleEvent %@ from %@", event, client];
}

static RACSignal *handleClient(SQRLXPCConnection *client) {
	return [[[[[[[client
		autoconnect]
		deliverOn:[RACScheduler schedulerWithPriority:RACSchedulerPriorityBackground]]
		catch:^(NSError *error) {
			NSLog(@"XPC error from client: %@", error);
			return [RACSignal empty];
		}]
		filter:^ BOOL (SQRLXPCObject *event) {
			return xpc_get_type(event.object) == XPC_TYPE_DICTIONARY;
		}]
		map:^(SQRLXPCObject *event) {
			return [handleEvent(event, client) sqrl_addSubscriptionTransactionWithName:NSLocalizedString(@"Preparing update", nil) description:NSLocalizedString(@"An update is being prepared. Interrupting the process could corrupt the application.", nil)];
		}]
		switchToLatest]
		setNameWithFormat:@"handleClient %@", client];
}

static void handleService(SQRLXPCConnection *service) {
	[[[[[[[service
		autoconnect]
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

