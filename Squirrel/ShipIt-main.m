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
#import "NSUserDefaults+SQRLShipItExtensions.h"
#import "SQRLArguments.h"
#import "SQRLInstaller.h"
#import "SQRLTerminationListener.h"
#import "SQRLXPCConnection.h"
#import "SQRLXPCObject.h"

// The domain for errors generated here.
static NSString * const SQRLShipItErrorDomain = @"SQRLShipItErrorDomain";

// A key required for a command was not provided.
static const NSInteger SQRLShipItErrorRequiredKeyMissing = 1;

// Starts installation based on the information in the given XPC event.
static RACSignal *installWithArgumentsFromEvent(SQRLXPCObject *event) {
	size_t requirementDataLen = 0;
	const void *requirementDataPtr = xpc_dictionary_get_data(event.object, SQRLCodeSigningRequirementKey, &requirementDataLen);

	NSURL *targetBundleURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event.object, SQRLTargetBundleURLKey))] filePathURL];
	NSURL *updateBundleURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event.object, SQRLUpdateBundleURLKey))] filePathURL];
	NSURL *applicationSupportURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event.object, SQRLApplicationSupportURLKey))] filePathURL];

	if (targetBundleURL == nil || updateBundleURL == nil || applicationSupportURL == nil || requirementDataPtr == NULL) {
		return [RACSignal error:[NSError errorWithDomain:SQRLShipItErrorDomain code:SQRLShipItErrorRequiredKeyMissing userInfo:@{ NSLocalizedDescriptionKey: @"Required key not provided" }]];
	}

	NSData *requirementData = [NSData dataWithBytes:requirementDataPtr length:requirementDataLen];
	BOOL shouldRelaunch = xpc_dictionary_get_bool(event.object, SQRLShouldRelaunchKey);

	RACSignal *termination = [RACSignal empty];
	const char *identifier = xpc_dictionary_get_string(event.object, SQRLWaitForBundleIdentifierKey);
	if (identifier != NULL) {
		SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithURL:targetBundleURL bundleIdentifier:@(identifier)];
		termination = [listener waitForTermination];
	}

	return [[[termination
		doCompleted:^{
			NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
			defaults.sqrl_targetBundleURL = targetBundleURL;
			defaults.sqrl_updateBundleURL = updateBundleURL;
			defaults.sqrl_applicationSupportURL = applicationSupportURL;
			defaults.sqrl_requirementData = requirementData;
			defaults.sqrl_relaunchAfterInstallation = shouldRelaunch;
			defaults.sqrl_state = SQRLShipItStateClearingQuarantine;
		}]
		then:^{
			return [[[[[SQRLInstaller.sharedInstaller.installUpdateCommand
				execute:nil]
				initially:^{
					xpc_transaction_begin();
					NSLog(@"Beginning installation");
				}]
				doCompleted:^{
					NSLog(@"Installation completed successfully");
				}]
				doError:^(NSError *error) {
					NSLog(@"Installation error: %@", error);
				}]
				finally:^{
					xpc_transaction_end();
				}];
		}]
		setNameWithFormat:@"installWithArgumentsFromEvent(%@)", event];
}

static SQRLXPCObject *replyFromDictionary(SQRLXPCObject *dictionary) {
	xpc_object_t reply = xpc_dictionary_create_reply(dictionary.object);
	if (reply == NULL) return nil;

	SQRLXPCObject *wrappedReply = [[SQRLXPCObject alloc] initWithXPCObject:reply];
	xpc_release(reply);

	return wrappedReply;
}

static RACSignal *handleEvent(SQRLXPCObject *event, SQRLXPCConnection *client) {
	const char *command = xpc_dictionary_get_string(event.object, SQRLShipItCommandKey);
	if (strcmp(command, SQRLShipItInstallCommand) != 0) return [RACSignal empty];

	xpc_connection_t remoteConnection = xpc_dictionary_get_remote_connection(event.object);

	return [[[[[[installWithArgumentsFromEvent(event)
		catch:^(NSError *error) {
			SQRLXPCObject *reply = replyFromDictionary(event);
			if (reply == nil) {
				NSLog(@"Received dictionary without a remote connection: %@", event);
			} else {
				xpc_dictionary_set_bool(reply.object, SQRLShipItSuccessKey, false);
				xpc_dictionary_set_string(reply.object, SQRLShipItErrorKey, error.localizedDescription.UTF8String);
				xpc_connection_send_message(remoteConnection, reply.object);
			}

			return [RACSignal error:error];
		}]
		flattenMap:^(NSRunningApplication *application) {
			if (remoteConnection == NULL) return [RACSignal empty];
			if (application.processIdentifier != xpc_connection_get_pid(remoteConnection)) return [RACSignal empty];

			return [RACSignal return:[[SQRLXPCConnection alloc] initWithXPCObject:remoteConnection]];
		}]
		flattenMap:^(SQRLXPCConnection *remoteConnection) {
			SQRLXPCObject *reply = replyFromDictionary(event);
			xpc_dictionary_set_bool(reply.object, SQRLShipItSuccessKey, true);

			return [[[remoteConnection
				sendMessageExpectingReply:reply]
				ignoreValues]
				// TODO: Cancel installation if we get a CONNECTION_INVALID
				// error (indicating that the remote process terminated before
				// we responded with success/error).
				catchTo:[RACSignal empty]];
		}]
		then:^{
			if (remoteConnection != NULL) {
				SQRLXPCObject *reply = replyFromDictionary(event);
				xpc_dictionary_set_bool(reply.object, SQRLShipItSuccessKey, true);
				xpc_connection_send_message(remoteConnection, reply.object);

				xpc_connection_send_barrier(remoteConnection, ^{
					exit(EXIT_SUCCESS);
				});
			}

			return [RACSignal empty];
		}]
		catch:^(NSError *error) {
			if (remoteConnection == NULL) return [RACSignal error:error];

			SQRLXPCObject *reply = replyFromDictionary(event);
			xpc_dictionary_set_bool(reply.object, SQRLShipItSuccessKey, false);
			xpc_dictionary_set_string(reply.object, SQRLShipItErrorKey, error.localizedDescription.UTF8String);
			xpc_connection_send_message(remoteConnection, reply.object);

			xpc_connection_send_barrier(remoteConnection, ^{
				exit(EXIT_FAILURE);
			});
			
			// Don't pass on the error, since we'll terminate when exit() is
			// called above.
			return [RACSignal empty];
		}]
		setNameWithFormat:@"handleEvent %@ from %@", event, client];
}

static RACSignal *handleClient(SQRLXPCConnection *client) {
	return [[[[[[[[[[[client
		autoconnect]
		deliverOn:[RACScheduler schedulerWithPriority:RACSchedulerPriorityBackground]]
		doNext:^(SQRLXPCObject *event) {
			NSLog(@"Got event on client connection: %@", event);
		}]
		catch:^(NSError *error) {
			NSLog(@"XPC error from client: %@", error);
			return [RACSignal empty];
		}]
		filter:^ BOOL (SQRLXPCObject *event) {
			return xpc_get_type(event.object) == XPC_TYPE_DICTIONARY;
		}]
		map:^(SQRLXPCObject *event) {
			return handleEvent(event, client);
		}]
		switchToLatest]
		initially:^{
			xpc_transaction_begin();
		}]
		finally:^{
			xpc_transaction_end();
		}]
		doCompleted:^{
			// When a client connection and all of its tasks complete without
			// issue (but _not_ when they're disposed from handleService), exit
			// ShipIt cleanly.
			exit(EXIT_SUCCESS);
		}]
		setNameWithFormat:@"handleClient %@", client];
}

static void handleService(SQRLXPCConnection *service) {
	[[[[[[[[service
		autoconnect]
		deliverOn:[RACScheduler schedulerWithPriority:RACSchedulerPriorityHigh]]
		catch:^(NSError *error) {
			NSLog(@"XPC error from service: %@", error);
			return [RACSignal empty];
		}]
		map:^(SQRLXPCObject *event) {
			return [[SQRLXPCConnection alloc] initWithXPCObject:event.object];
		}]
		doNext:^(SQRLXPCConnection *client) {
			NSLog(@"Got client connection: %@", client);
		}]
		map:^(SQRLXPCConnection *client) {
			return handleClient(client);
		}]
		switchToLatest]
		subscribeError:^(NSError *error) {
			NSLog(@"%@", error);
		} completed:^{
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
		NSLog(@"ShipIt started with Mach service name \"%s\"", serviceName);

		xpc_connection_t service = xpc_connection_create_mach_service(serviceName, NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
		if (service == NULL) {
			NSLog(@"Could not start Mach service \"%s\"", serviceName);
			exit(EXIT_FAILURE);
		}

		@onExit {
			xpc_release(service);
		};

		handleService([[SQRLXPCConnection alloc] initWithXPCObject:service]);
		dispatch_main();
	}

	return EXIT_SUCCESS;
}

