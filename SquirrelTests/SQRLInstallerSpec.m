//
//  SQRLInstallerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignatureVerification.h"

SpecBegin(SQRLInstaller)

__block NSURL *updateURL;
__block xpc_connection_t shipitConnection;
__block xpc_object_t message;

beforeEach(^{
	updateURL = [self createTestApplicationUpdate];
	shipitConnection = [self connectToShipIt];

	message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(message, SQRLShipItCommandKey, SQRLShipItInstallCommand);

	xpc_dictionary_set_string(message, SQRLTargetBundleURLKey, self.testApplicationURL.absoluteString.UTF8String);
	xpc_dictionary_set_string(message, SQRLUpdateBundleURLKey, updateURL.absoluteString.UTF8String);
	xpc_dictionary_set_string(message, SQRLBackupURLKey, self.temporaryDirectoryURL.absoluteString.UTF8String);
	xpc_dictionary_set_bool(message, SQRLShouldRelaunchKey, false);
	xpc_dictionary_set_bool(message, SQRLWaitForConnectionKey, false);
});

it(@"should install an update", ^{
	__block BOOL installed = NO;

	xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
		expect(xpc_dictionary_get_bool(event, SQRLShipItSuccessKey)).to.beTruthy();
		expect([self errorFromObject:event]).to.beNil();

		installed = YES;
	});

	expect(installed).will.beTruthy();
	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should install an update and relaunch", ^{
	__block BOOL installed = NO;

	NSString *bundleIdentifier = @"com.github.Squirrel.TestApplication";
	NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
	expect(apps.count).to.equal(0);

	xpc_dictionary_set_bool(message, SQRLShouldRelaunchKey, true);
	xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
		expect(xpc_dictionary_get_bool(event, SQRLShipItSuccessKey)).to.beTruthy();
		expect([self errorFromObject:event]).to.beNil();

		installed = YES;
	});

	expect(installed).will.beTruthy();
	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	expect([NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier].count).will.equal(1);
});

describe(@"signal handling", ^{
	__block void (^sendThenCancel)(void);

	beforeEach(^{
		sendThenCancel = ^{
			xpc_connection_send_message(shipitConnection, message);
			xpc_connection_send_barrier(shipitConnection, ^{
				xpc_connection_cancel(shipitConnection);
			});

			// Apply a random delay before sending the termination signal, to
			// fuzz out race conditions.
			u_int32_t msDelay = arc4random_uniform(80);
			[NSThread sleepForTimeInterval:msDelay / 1000.0];
		};
	});

	afterEach(^{
		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:self.testApplicationBundle.bundleURL error:&error];
		expect(success).to.beTruthy();
		expect(error).to.beNil();
	});

	it(@"should leave the target in a valid state after being sent SIGHUP", ^{
		sendThenCancel();
		expect(system("killall -HUP ShipIt")).to.equal(0);
	});

	it(@"should leave the target in a valid state after being sent SIGTERM", ^{
		sendThenCancel();
		expect(system("killall -TERM ShipIt")).to.equal(0);
	});

	it(@"should leave the target in a valid state after being sent SIGKILL", ^{
		sendThenCancel();
		expect(system("killall -KILL ShipIt")).to.equal(0);
	});
});

SpecEnd
