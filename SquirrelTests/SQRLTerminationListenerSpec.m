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
__block xpc_connection_t shipitConnection;

beforeEach(^{
	testApplication = [self launchTestApplication];

	shipitConnection = xpc_connection_create(SQRLShipItServiceLabel, dispatch_get_main_queue());
	expect(shipitConnection).notTo.beNil();
	
	xpc_connection_set_event_handler(shipitConnection, ^(xpc_object_t event) {
		NSLog(@"shipit event: %s", xpc_copy_description(event));

		xpc_type_t type = xpc_get_type(event);
		if (type == XPC_TYPE_ERROR && event != XPC_ERROR_CONNECTION_INVALID) {
			NSAssert(NO, @"XPC connection failed with error: %s", xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
		}
	});

	xpc_connection_resume(shipitConnection);
});

it(@"should listen for termination of the parent process", ^{
	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(message, SQRLShipItCommandKey, SQRLShipItListenForTerminationCommand);

	xpc_dictionary_set_int64(message, SQRLProcessIdentifierKey, testApplication.processIdentifier);
	xpc_dictionary_set_string(message, SQRLBundleIdentifierKey, testApplication.bundleIdentifier.UTF8String);
	xpc_dictionary_set_string(message, SQRLTargetBundleURLKey, testApplication.bundleURL.absoluteString.UTF8String);

	__block BOOL terminated = NO;

	xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
		NSLog(@"shipit reply: %s", xpc_copy_description(event));
		expect(xpc_dictionary_get_bool(event, SQRLShipItSuccessKey)).to.beTruthy();
		expect(xpc_dictionary_get_string(event, SQRLShipItErrorKey)).to.beNil();

		terminated = YES;
	});

	expect(terminated).to.beFalsy();

	[testApplication forceTerminate];
	expect(terminated).will.beTruthy();
});

afterEach(^{
	xpc_connection_cancel(shipitConnection);
	xpc_release(shipitConnection);
});

SpecEnd
