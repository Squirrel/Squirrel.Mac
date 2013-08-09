//
//  SQRLTerminationListenerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

SpecBegin(SQRLTerminationListener)

__block NSRunningApplication *testApplication;
__block xpc_connection_t shipitConnection;

beforeEach(^{
	testApplication = [self launchTestApplication];
	shipitConnection = [self connectToShipIt];
});

it(@"should listen for termination of the parent process", ^{
	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(message, SQRLShipItCommandKey, SQRLShipItListenForTerminationCommand);

	xpc_dictionary_set_int64(message, SQRLProcessIdentifierKey, testApplication.processIdentifier);
	xpc_dictionary_set_string(message, SQRLBundleIdentifierKey, testApplication.bundleIdentifier.UTF8String);
	xpc_dictionary_set_string(message, SQRLTargetBundleURLKey, testApplication.bundleURL.absoluteString.UTF8String);

	__block BOOL terminated = NO;

	xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
		expect(xpc_dictionary_get_bool(event, SQRLShipItSuccessKey)).to.beTruthy();
		expect([self errorFromObject:event]).to.beNil();

		terminated = YES;
	});

	expect(terminated).to.beFalsy();

	[testApplication forceTerminate];
	expect(terminated).will.beTruthy();
});

SpecEnd
