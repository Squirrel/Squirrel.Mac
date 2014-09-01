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
#import "SQRLDirectoryManager.h"
#import "SQRLInstaller.h"
#import "SQRLInstaller+Private.h"
#import "SQRLShipItRequest.h"

// The domain for errors generated here.
static NSString * const SQRLShipItErrorDomain = @"SQRLShipItErrorDomain";

typedef NS_ENUM(NSInteger, SQRLShipItError) {
	SQRLShipItErrorUnknownAction,
	SQRLShipItErrorMissingRequestData,
};

static void reply(xpc_object_t response) {
	xpc_connection_t connection = xpc_dictionary_get_remote_connection(response);
	xpc_connection_send_message(connection, response);
}

static void replyWithError(xpc_object_t response, NSError *error) {
	xpc_dictionary_set_bool(response, "success", false);

	if (error != nil) {
		xpc_object_t errorDictionary = xpc_dictionary_create(NULL, NULL, 0);
		xpc_dictionary_set_string(errorDictionary, "domain", error.domain.UTF8String);
		xpc_dictionary_set_int64(errorDictionary, "code", error.code);
		xpc_dictionary_set_string(errorDictionary, "description", error.localizedDescription.UTF8String);
		xpc_dictionary_set_string(errorDictionary, "failureReason", error.localizedFailureReason.UTF8String);
		xpc_dictionary_set_string(errorDictionary, "recoverySuggestion", error.localizedRecoverySuggestion.UTF8String);
		xpc_dictionary_set_value(response, "error", errorDictionary);
		xpc_release(errorDictionary);
	}

	reply(response);
}

static void replyWithSuccess(xpc_object_t response) {
	xpc_dictionary_set_bool(response, "success", true);
	reply(response);
}

// Client requests from peer connections.
//
// applicationIdentifier - Current process reverse DNS identifier.
// request               - XPC dictionary request object.
//
// Returns nothing.
static void handleRequest(NSString *applicationIdentifier, xpc_object_t request) {
	xpc_object_t response = xpc_dictionary_create_reply(request);

	SQRLInstaller *installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:applicationIdentifier];

	char const *action = xpc_dictionary_get_string(request, "action");
	if (strcmp(action, "install") != 0) {
		NSDictionary *errorInfo = @{
			NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot process \"%s\" requests", action],
		};
		replyWithError(response, [NSError errorWithDomain:SQRLShipItErrorDomain code:SQRLShipItErrorUnknownAction userInfo:errorInfo]);
		return;
	}

	size_t length;
	void const *requestBytes = xpc_dictionary_get_data(request, "request", &length);
	if (requestBytes == NULL) {
		NSDictionary *errorInfo = @{
			NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot process \"%s\" requests without \"request\" data", action],
		};
		replyWithError(response, [NSError errorWithDomain:SQRLShipItErrorDomain code:SQRLShipItErrorUnknownAction userInfo:errorInfo]);
		return;
	}

	[[[SQRLShipItRequest
		readFromData:[NSData dataWithBytes:requestBytes length:length] ]
		flattenMap:^(SQRLShipItRequest *request) {
			return [[installer.installUpdateCommand
				execute:request]
				catch:^(NSError *error) {
					return [[[installer.abortInstallationCommand
						execute:nil]
						doCompleted:^{
							NSLog(@"Abort completed successfully");
						}]
						concat:[RACSignal error:error]];
					}];
		}]
		subscribeError:^(NSError *error){
			NSLog(@"Installation failed with error: %@ %@", error, error.userInfo);
			replyWithError(response, error);
		} completed:^{
			NSLog(@"Installation completed successfully");
			replyWithSuccess(response);
		}];
}

// Peer connections from the listener connection.
//
// applicationIdentifier - Current process reverse DNS identifier.
// newConnection         - The newly accepted connection from the listener.
//
// Returns nothing.
static void handleConnection(NSString *applicationIdentifier, xpc_connection_t newConnection) {
	xpc_connection_set_event_handler(newConnection, ^(xpc_object_t object) {
		xpc_type_t type = xpc_get_type(object);
		if (type == XPC_TYPE_ERROR) {
			char *description = xpc_copy_description(object);
			NSLog(@"XPC peer error: %s", description);
			free(description);
			return;
		}

		if (type != XPC_TYPE_DICTIONARY) {
			NSLog(@"XPC peer expected dictionary");
			return;
		}

		handleRequest(applicationIdentifier, object);
	});
	xpc_connection_resume(newConnection);
}

// Listens for XPC messages from clients.
//
// Arguments are expected in the following order:
//
// jobLabel - The launchd job label for this task.
//
// Returns 0 on successful termination, non 0 otherwise.
int main(int argc, const char * argv[]) {
	@autoreleasepool {
		atexit_b(^{
			NSLog(@"ShipIt quitting");
		});

		if (argc < 2) {
			NSLog(@"Missing launchd job label for ShipIt");
			return EXIT_FAILURE;
		}
		char const *jobLabel = argv[1];
		NSString *applicationIdentifier = @(jobLabel);

		xpc_connection_t server = xpc_connection_create_mach_service(jobLabel, NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
		xpc_connection_set_event_handler(server, ^(xpc_object_t object) {
			xpc_type_t type = xpc_get_type(object);
			if (type == XPC_TYPE_ERROR) {
				char *description = xpc_copy_description(object);
				NSLog(@"XPC listener error: %s", description);
				free(description);
			} else if (type == XPC_TYPE_CONNECTION) {
				handleConnection(applicationIdentifier, object);
			}
		});
		xpc_connection_resume(server);

		dispatch_main();
	}

	return EXIT_SUCCESS;
}
