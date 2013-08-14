//
//  SQRLInstallerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignatureVerifier.h"

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

	NSData *requirementData = self.testApplicationCodeSigningRequirementData;
	xpc_dictionary_set_data(message, SQRLCodeSigningRequirementKey, requirementData.bytes, requirementData.length);
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
	__block NSURL *targetURL;

	beforeEach(^{
		// Copied so that we don't recreate the TestApplication bundle by
		// accessing the property.
		targetURL = self.testApplicationURL;

		sendThenCancel = ^{
			xpc_connection_send_message(shipitConnection, message);

			__block BOOL launched = NO;
			xpc_connection_send_barrier(shipitConnection, ^{
				launched = YES;
				xpc_connection_cancel(shipitConnection);
			});
			
			// Make sure that ShipIt is running before we try sending it
			// a signal.
			expect(launched).will.beTruthy();

			// Apply a random delay before sending the termination signal, to
			// fuzz out race conditions.
			[NSThread sleepForTimeInterval:arc4random_uniform(100) / 1000.0];
		};
	});

	describe(@"with a guaranteed target bundle", ^{
		afterEach(^{
			BOOL (^processExists)(void) = ^ BOOL {
				int result = system("killall -s ShipIt");
				expect(result).notTo.equal(-1);
				expect(result).notTo.equal(127);
				return WEXITSTATUS(result) != 1;
			};

			// Wait until ShipIt isn't running anymore before verifying the code
			// signature.
			expect(processExists()).will.beFalsy();

			NSError *error = nil;
			BOOL success = [self.testApplicationVerifier verifyCodeSignatureOfBundle:targetURL error:&error];
			expect(success).to.beTruthy();
			expect(error).to.beNil();
		});

		it(@"should handle SIGHUP", ^{
			sendThenCancel();
			system("killall -HUP ShipIt");
		});

		it(@"should handle SIGTERM", ^{
			sendThenCancel();
			system("killall -TERM ShipIt");
		});

		it(@"should handle SIGINT", ^{
			sendThenCancel();
			system("killall -INT ShipIt");
		});

		it(@"should handle SIGQUIT", ^{
			sendThenCancel();
			system("killall -QUIT ShipIt");
		});
	});

	it(@"should leave the target missing or in a valid state after being sent SIGKILL", ^{
		sendThenCancel();
		system("killall -KILL ShipIt");

		// Our behavior can't be as well-defined in the case of SIGKILL (since
		// we get no opportunity to handle it), but we should at least guarantee
		// that:
		//
		//  1. The target bundle is missing, or
		//  2. The target bundle passes code signing.
		//
		// Any corruption of the target bundle is a critical failure.
		if ([NSFileManager.defaultManager fileExistsAtPath:targetURL.path]) {
			NSError *error = nil;
			BOOL success = [self.testApplicationVerifier verifyCodeSignatureOfBundle:targetURL error:&error];
			expect(success).to.beTruthy();
			expect(error).to.beNil();
		}
	});
});

SpecEnd
