//
//  SQRLTerminationListenerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLArguments+Private.h"

SpecBegin(SQRLTerminationListener)

__block xpc_connection_t testServiceConnection;
__block xpc_connection_t shipitListener;
__block xpc_connection_t toShipitEndpoint;

beforeEach(^{
	shipitListener = xpc_connection_create(NULL, dispatch_get_main_queue());
	expect(shipitListener).notTo.beNil();
	
	xpc_connection_set_event_handler(shipitListener, ^(xpc_object_t event) {
		NSLog(@"shipit listener event: %s", xpc_copy_description(event));

		xpc_type_t type = xpc_get_type(event);
		if (type == XPC_TYPE_ERROR && event != XPC_ERROR_CONNECTION_INVALID) {
			NSAssert(NO, @"XPC connection failed with error: %s", xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
		}
	});

	testServiceConnection = xpc_connection_create(SQRLTestXPCServiceLabel, dispatch_get_main_queue());
	expect(testServiceConnection).notTo.beNil();

	xpc_connection_set_event_handler(testServiceConnection, ^(xpc_object_t event) {
		NSLog(@"TestService event: %s", xpc_copy_description(event));

		xpc_type_t type = xpc_get_type(event);
		if (type == XPC_TYPE_ERROR && event != XPC_ERROR_CONNECTION_INVALID) {
			NSAssert(NO, @"XPC connection failed with error: %s", xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
		}
	});

	xpc_connection_resume(shipitListener);
	xpc_connection_resume(testServiceConnection);

	toShipitEndpoint = xpc_connection_create_from_endpoint(xpc_endpoint_create(shipitListener));
	expect(toShipitEndpoint).notTo.beNil();

	xpc_endpoint_t fromShipitEndpoint = xpc_endpoint_create(shipitListener);
	expect(fromShipitEndpoint).notTo.beNil();

	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_value(message, SQRLShipitEndpointKey, fromShipitEndpoint);
	xpc_connection_send_message(testServiceConnection, message);
});

it(@"should listen for termination of the parent process", ^{
	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(message, SQRLCommandKey, SQRLCommandListenForTermination);

	__block BOOL terminated = NO;

	xpc_connection_send_message_with_reply(toShipitEndpoint, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
		NSLog(@"shipit reply: %s", xpc_copy_description(event));
		expect(xpc_get_type(event)).notTo.equal(XPC_TYPE_ERROR);

		terminated = YES;
	});

	expect(terminated).will.beTruthy();
});

afterEach(^{
	xpc_connection_cancel(toShipitEndpoint);
	xpc_release(toShipitEndpoint);

	xpc_connection_cancel(shipitListener);
	xpc_release(shipitListener);

	xpc_connection_cancel(testServiceConnection);
	xpc_release(testServiceConnection);
});

SpecEnd
