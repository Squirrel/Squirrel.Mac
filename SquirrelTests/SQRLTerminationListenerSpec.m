//
//  SQRLTerminationListenerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLArguments+Private.h"

SpecBegin(SQRLTerminationListener)

__block NSRunningApplication *testApplication;
__block xpc_connection_t testAppConnection;
__block xpc_connection_t shipitConnection;

beforeEach(^{
	NSURL *testApplicationURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication" withExtension:@"app"];
	expect(testApplicationURL).notTo.beNil();

	NSError *error = nil;
	testApplication = [NSWorkspace.sharedWorkspace launchApplicationAtURL:testApplicationURL options:NSWorkspaceLaunchWithoutAddingToRecents | NSWorkspaceLaunchWithoutActivation | NSWorkspaceLaunchNewInstance | NSWorkspaceLaunchAndHide configuration:nil error:&error];
	expect(testApplication).notTo.beNil();
	expect(error).to.beNil();

	NSLog(@"Launched TestApplication: %@", testApplication);

	shipitConnection = xpc_connection_create(NULL, dispatch_get_main_queue());
	expect(shipitConnection).notTo.beNil();
	
	xpc_connection_set_event_handler(shipitConnection, ^(xpc_object_t event) {
		NSLog(@"shipit event: %s", xpc_copy_description(event));

		xpc_type_t type = xpc_get_type(event);
		if (type == XPC_TYPE_ERROR && event != XPC_ERROR_CONNECTION_INVALID) {
			NSAssert(NO, @"XPC connection failed with error: %s", xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
		}
	});

	testAppConnection = xpc_connection_create_mach_service(SQRLTestApplicationServiceLabel, dispatch_get_main_queue(), 0);
	expect(testAppConnection).notTo.beNil();

	xpc_connection_set_event_handler(testAppConnection, ^(xpc_object_t event) {
		NSLog(@"TestApp event: %s", xpc_copy_description(event));

		xpc_type_t type = xpc_get_type(event);
		if (type == XPC_TYPE_ERROR && event != XPC_ERROR_CONNECTION_INVALID) {
			NSAssert(NO, @"XPC connection failed with error: %s", xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
		}
	});

	xpc_connection_resume(shipitConnection);
	xpc_connection_resume(testAppConnection);

	xpc_endpoint_t shipitEndpoint = xpc_endpoint_create(shipitConnection);
	expect(shipitEndpoint).notTo.beNil();

	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_value(message, SQRLShipitEndpointKey, shipitEndpoint);
	xpc_connection_send_message(testAppConnection, message);
});

it(@"should listen for termination of the parent process", ^{
	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(message, SQRLCommandKey, SQRLCommandListenForTermination);

	__block BOOL terminated = NO;

	xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
		NSLog(@"shipit reply: %s", xpc_copy_description(event));
		expect(xpc_get_type(event)).notTo.equal(XPC_TYPE_ERROR);

		terminated = YES;
	});

	expect(terminated).will.beTruthy();
});

afterEach(^{
	xpc_connection_cancel(shipitConnection);
	xpc_release(shipitConnection);

	xpc_connection_cancel(testAppConnection);
	xpc_release(testAppConnection);

	if (!testApplication.terminated) {
		[testApplication terminate];
		[testApplication forceTerminate];
	}
});

SpecEnd
