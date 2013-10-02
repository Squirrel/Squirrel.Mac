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
#import "SQRLArguments.h"
#import "SQRLInstaller.h"
#import "SQRLXPCConnection.h"
#import "SQRLXPCObject.h"

// The domain for errors generated here.
static NSString * const SQRLShipItErrorDomain = @"SQRLShipItErrorDomain";

// A key required for a command was not provided.
static const NSInteger SQRLShipItErrorRequiredKeyMissing = 1;

// How long to wait after connection termination before installing an update.
//
// Although a terminated connection usually indicates that the parent
// application has quit and is ready to be updated, it may still take a very
// short period of time for it to finish shutting down. We use this delay to
// ensure that the parent application has definitely terminated before we begin
// the installation process.
//
// Unfortunately, other mechanisms for watching application termination do not
// generally work when one side is a GUI application, and the watcher is
// a command line tool.
static const NSTimeInterval SQRLUpdaterInstallationDelay = 0.1;

// Prepares installation based on the information in the given XPC event.
//
// Returns a signal which will error if information required for installation
// is missing, or else send a cold inner signal that will actually perform the
// installation when subscribed to.
static RACSignal *signalOfDeferredInstallationSignal(SQRLXPCObject *event) {
	size_t requirementDataLen = 0;
	const void *requirementDataPtr = xpc_dictionary_get_data(event.object, SQRLCodeSigningRequirementKey, &requirementDataLen);

	NSURL *targetBundleURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event.object, SQRLTargetBundleURLKey))] filePathURL];
	NSURL *updateBundleURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event.object, SQRLUpdateBundleURLKey))] filePathURL];

	if (targetBundleURL == nil || updateBundleURL == nil || requirementDataPtr == NULL) {
		return [RACSignal error:[NSError errorWithDomain:SQRLShipItErrorDomain code:SQRLShipItErrorRequiredKeyMissing userInfo:@{ NSLocalizedDescriptionKey: @"Required key not provided" }]];
	}

	NSData *requirementData = [NSData dataWithBytes:requirementDataPtr length:requirementDataLen];
	BOOL shouldRelaunch = xpc_dictionary_get_bool(event.object, SQRLShouldRelaunchKey);

	RACSignal *installationSignal = [[[[[[[[RACSignal
		defer:^{
			SQRLInstaller *installer = [[SQRLInstaller alloc] initWithTargetBundleURL:targetBundleURL updateBundleURL:updateBundleURL requirementData:requirementData];
			return [installer installUpdate];
		}]
		then:^{
			if (!shouldRelaunch) return [RACSignal empty];

			NSError *error = nil;
			if ([NSWorkspace.sharedWorkspace launchApplicationAtURL:targetBundleURL options:NSWorkspaceLaunchDefault configuration:nil error:&error]) {
				NSLog(@"Application relaunched");
				return [RACSignal empty];
			} else {
				return [RACSignal error:error];
			}
		}]
		initially:^{
			xpc_transaction_begin();
			NSLog(@"Beginning installation");
		}]
		finally:^{
			xpc_transaction_end();
		}]
		doCompleted:^{
			NSLog(@"Installation completed successfully");
		}]
		doError:^(NSError *error) {
			NSLog(@"Installation error: %@", error);
		}]
		replayLazily]
		setNameWithFormat:@"installationSignal"];
	
	return [RACSignal return:installationSignal];
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

	SQRLXPCConnection *remoteConnection = [[SQRLXPCConnection alloc] initWithXPCObject:xpc_dictionary_get_remote_connection(event.object)];

	return [[[signalOfDeferredInstallationSignal(event)
		catch:^(NSError *error) {
			SQRLXPCObject *reply = replyFromDictionary(event);
			if (reply == nil) {
				NSLog(@"Received dictionary without a remote connection: %@", event);
			} else {
				xpc_dictionary_set_bool(reply.object, SQRLShipItSuccessKey, false);
				xpc_dictionary_set_string(reply.object, SQRLShipItErrorKey, error.localizedDescription.UTF8String);
				xpc_connection_send_message(remoteConnection.object, reply.object);
			}

			return [RACSignal error:error];
		}]
		flattenMap:^(RACSignal *install) {
			SQRLXPCObject *reply = replyFromDictionary(event);
			if (reply == nil) {
				NSLog(@"Received dictionary without a remote connection: %@", event);
			}

			if (remoteConnection != nil && xpc_dictionary_get_bool(event.object, SQRLWaitForConnectionKey)) {
				xpc_dictionary_set_bool(reply.object, SQRLShipItSuccessKey, true);

				return [[[remoteConnection
					sendMessageExpectingReply:reply]
					ignoreValues]
					catch:^(NSError *error) {
						if (![error.domain isEqual:SQRLXPCErrorDomain]) return [RACSignal error:error];
						if (error.code != SQRLXPCErrorConnectionInterrupted && error.code != SQRLXPCErrorConnectionInvalid) return [RACSignal error:error];

						// At this point, the client application has
						// terminated, so actually begin installing.
						[client cancel];
						NSLog(@"Waiting for %g seconds before installing", SQRLUpdaterInstallationDelay);

						return [[[RACSignal
							interval:SQRLUpdaterInstallationDelay onScheduler:[RACScheduler scheduler]]
							take:1]
							flattenMap:^(id _) {
								return install;
							}];
					}];
			} else if (reply != nil) {
				return [[install
					doError:^(NSError *error) {
						xpc_dictionary_set_bool(reply.object, SQRLShipItSuccessKey, false);
						xpc_dictionary_set_string(reply.object, SQRLShipItErrorKey, error.localizedDescription.UTF8String);
						xpc_connection_send_message(remoteConnection.object, reply.object);

						xpc_connection_send_barrier(remoteConnection.object, ^{
							exit(EXIT_FAILURE);
						});
					}]
					doCompleted:^{
						xpc_dictionary_set_bool(reply.object, SQRLShipItSuccessKey, true);
						xpc_connection_send_message(remoteConnection.object, reply.object);

						xpc_connection_send_barrier(remoteConnection.object, ^{
							exit(EXIT_SUCCESS);
						});
					}];
			} else {
				return [install finally:^{
					[client cancel];
				}];
			}
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

