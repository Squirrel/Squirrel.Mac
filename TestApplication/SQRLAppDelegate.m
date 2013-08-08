//
//  SQRLAppDelegate.m
//  TestApplication
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLAppDelegate.h"
#import "SQRLArguments+Private.h"

static BOOL checkForXPCTermination(xpc_object_t event) {
	xpc_type_t type = xpc_get_type(event);
	if (type == XPC_TYPE_ERROR) {
		if (event == XPC_ERROR_CONNECTION_INVALID) {
			return YES;
		} else {
			NSCAssert(NO, @"XPC error: %s", xpc_copy_description(event));
		}
	}

	return NO;
}

@implementation SQRLAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	xpc_connection_t service = xpc_connection_create_mach_service(SQRLTestApplicationServiceLabel, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
	NSCAssert(service != NULL, @"Failed to create %s service", SQRLTestApplicationServiceLabel);

	xpc_connection_t shipitConnection = xpc_connection_create_mach_service(SQRLShipitServiceLabel, dispatch_get_main_queue(), 0);
	NSCAssert(shipitConnection != NULL, @"Failed to create connection to %s", SQRLShipitServiceLabel);
	
	xpc_connection_set_event_handler(service, ^(xpc_object_t connection) {
		NSLog(@"Got client connection: %s", xpc_copy_description(connection));
		if (checkForXPCTermination(connection)) exit(EXIT_SUCCESS);

		xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
			NSLog(@"Got event on client connection: %s", xpc_copy_description(event));
			if (checkForXPCTermination(event)) exit(EXIT_SUCCESS);

			// Forward any endpoints to shipit.
			xpc_connection_send_message(shipitConnection, event);
		});

		xpc_connection_resume(connection);
	});
	
	xpc_connection_set_event_handler(shipitConnection, ^(xpc_object_t event) {
		NSLog(@"Got event on shipit connection: %s", xpc_copy_description(event));
		if (checkForXPCTermination(shipitConnection)) exit(EXIT_SUCCESS);
	});

	xpc_connection_resume(shipitConnection);
	xpc_connection_resume(service);
}

@end
