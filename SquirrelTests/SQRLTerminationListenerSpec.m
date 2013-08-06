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
__block xpc_connection_t connection;

beforeEach(^{
	NSURL *testApplicationURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication" withExtension:@"app"];
	expect(testApplicationURL).notTo.beNil();

	NSError *error = nil;
	testApplication = [NSWorkspace.sharedWorkspace launchApplicationAtURL:testApplicationURL options:NSWorkspaceLaunchWithoutAddingToRecents | NSWorkspaceLaunchWithoutActivation | NSWorkspaceLaunchNewInstance | NSWorkspaceLaunchAndHide configuration:nil error:&error];
	expect(testApplication).notTo.beNil();
	expect(error).to.beNil();

	NSLog(@"Launched TestApplication: %@", testApplication);

	connection = xpc_connection_create_mach_service(SQRLShipitServiceLabel, dispatch_get_main_queue(), 0);
	expect(connection).notTo.beNil();

	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
		xpc_type_t type = xpc_get_type(event);
		if (type == XPC_TYPE_ERROR) {
			NSAssert(NO, @"XPC connection failed with error: %s", xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
		}
	});

	xpc_connection_resume(connection);
});

it(@"should listen for termination of the parent process", ^{
	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(message, SQRLCommandKey, SQRLCommandListenForTermination);

	__block BOOL terminated = NO;

	xpc_connection_send_message_with_reply(connection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
		xpc_type_t type = xpc_get_type(event);
		if (type == XPC_TYPE_ERROR) return;

		terminated = YES;
	});

	expect(terminated).will.beTruthy();
});

afterEach(^{
	xpc_connection_cancel(connection);
	xpc_release(connection);

	if (!testApplication.terminated) {
		[testApplication terminate];
		[testApplication forceTerminate];
	}
});

SpecEnd
