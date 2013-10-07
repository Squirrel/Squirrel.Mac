//
//  SQRLInstallerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignatureVerifier.h"
#import "SQRLInstaller.h"
#import "SQRLShipItLauncher.h"
#import "SQRLStateManager.h"

SpecBegin(SQRLInstaller)

describe(@"after connecting to ShipIt", ^{
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
		xpc_dictionary_set_string(message, SQRLApplicationSupportURLKey, self.temporaryDirectoryURL.absoluteString.UTF8String);
		xpc_dictionary_set_bool(message, SQRLShouldRelaunchKey, false);

		NSData *requirementData = self.testApplicationCodeSigningRequirementData;
		xpc_dictionary_set_data(message, SQRLCodeSigningRequirementKey, requirementData.bytes, requirementData.length);
	});

	afterEach(^{
		xpc_release(message);
	});

	it(@"should install an update", ^{
		__block BOOL ready = NO;

		xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
			expect(xpc_dictionary_get_bool(event, SQRLShipItSuccessKey)).to.beTruthy();
			expect([self errorFromObject:event]).to.beNil();

			ready = YES;
		});

		expect(ready).will.beTruthy();
		expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	});

	it(@"should install an update and relaunch", ^{
		NSString *bundleIdentifier = @"com.github.Squirrel.TestApplication";
		NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
		expect(apps.count).to.equal(0);

		__block BOOL ready = NO;

		xpc_dictionary_set_bool(message, SQRLShouldRelaunchKey, true);
		xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
			expect(xpc_dictionary_get_bool(event, SQRLShipItSuccessKey)).to.beTruthy();
			expect([self errorFromObject:event]).to.beNil();

			ready = YES;
		});

		expect(ready).will.beTruthy();
		expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
		expect([NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier].count).will.equal(1);
	});

	it(@"should install an update from another volume", ^{
		NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication 2.1" fromDirectory:updateURL.URLByDeletingLastPathComponent];
		updateURL = [diskImageURL URLByAppendingPathComponent:updateURL.lastPathComponent];

		__block BOOL ready = NO;

		xpc_dictionary_set_string(message, SQRLUpdateBundleURLKey, updateURL.absoluteString.UTF8String);
		xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
			expect(xpc_dictionary_get_bool(event, SQRLShipItSuccessKey)).to.beTruthy();
			expect([self errorFromObject:event]).to.beNil();

			ready = YES;
		});

		expect(ready).will.beTruthy();
		expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	});

	it(@"should install an update to another volume", ^{
		NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication" fromDirectory:self.testApplicationURL.URLByDeletingLastPathComponent];
		NSURL *targetURL = [diskImageURL URLByAppendingPathComponent:self.testApplicationURL.lastPathComponent];

		__block BOOL ready = NO;

		xpc_dictionary_set_string(message, SQRLTargetBundleURLKey, targetURL.absoluteString.UTF8String);
		xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
			expect(xpc_dictionary_get_bool(event, SQRLShipItSuccessKey)).to.beTruthy();
			expect([self errorFromObject:event]).to.beNil();

			ready = YES;
		});

		expect(ready).will.beTruthy();

		NSURL *plistURL = [targetURL URLByAppendingPathComponent:@"Contents/Info.plist"];
		expect([NSDictionary dictionaryWithContentsOfURL:plistURL][SQRLBundleShortVersionStringKey]).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	});

	it(@"should not install an update if the connection closes too early", ^{
		__block BOOL canceled = NO;
		__block BOOL receivedReply = NO;

		xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t reply) {
			if (xpc_get_type(reply) == XPC_TYPE_ERROR) return;
			receivedReply = YES;
		});
		
		xpc_connection_send_barrier(shipitConnection, ^{
			xpc_connection_cancel(shipitConnection);
			canceled = YES;
		});

		expect(canceled).will.beTruthy();
		
		// If we received a reply from ShipIt, installation has already begun. We're too late.
		expect(receivedReply).to.beFalsy();

		[NSThread sleepForTimeInterval:0.2];

		// No update should've been installed, since our side of the connection was
		// terminated before we could receive the reply from ShipIt.
		expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
	});

	describe(@"signal handling", ^{
		__block BOOL terminated;
		__block void (^sendMessage)(void);

		__block NSURL *targetURL;

		beforeEach(^{
			// Copied so that we don't recreate the TestApplication bundle by
			// accessing the property.
			targetURL = self.testApplicationURL;

			terminated = NO;
			xpc_connection_set_event_handler(shipitConnection, ^(xpc_object_t event) {
				if (event == XPC_ERROR_CONNECTION_INVALID || event == XPC_ERROR_CONNECTION_INTERRUPTED) {
					terminated = YES;
				}
			});

			sendMessage = ^{
				__block BOOL ready = NO;

				xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
					expect(xpc_dictionary_get_bool(event, SQRLShipItSuccessKey)).to.beTruthy();
					expect([self errorFromObject:event]).to.beNil();

					ready = YES;
				});

				expect(ready).will.beTruthy();

				// Apply a random delay before sending the termination signal, to
				// fuzz out race conditions.
				NSTimeInterval delay = arc4random_uniform(50) / 1000.0;
				[NSThread sleepForTimeInterval:delay];
			};
		});

		afterEach(^{
			// Wait until ShipIt isn't running anymore before verifying the code
			// signature.
			expect(terminated).will.beTruthy();

			// Wait for the launchd throttle interval, then verify that ShipIt
			// relaunched and finished installing the update.
			Expecta.asynchronousTestTimeout = 5;
			expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);

			NSError *error = nil;
			BOOL success = [[self.testApplicationVerifier verifyCodeSignatureOfBundle:targetURL] waitUntilCompleted:&error];
			expect(success).to.beTruthy();
			expect(error).to.beNil();
		});

		it(@"should handle SIGHUP", ^{
			sendMessage();
			system("killall -v -HUP ShipIt");
		});

		it(@"should handle SIGTERM", ^{
			sendMessage();
			system("killall -v -TERM ShipIt");
		});

		it(@"should handle SIGINT", ^{
			sendMessage();
			system("killall -v -INT ShipIt");
		});

		it(@"should handle SIGQUIT", ^{
			sendMessage();
			system("killall -v -QUIT ShipIt");
		});

		it(@"should handle SIGKILL", ^{
			sendMessage();

			// SIGKILL is unique in that it'll always terminate ShipIt, so send it
			// a few times to really test resumption.
			for (int i = 0; i < 3; i++) {
				system("killall -v -KILL ShipIt");

				// Wait at least for the launchd throttle interval.
				NSTimeInterval delay = 2 + (arc4random_uniform(100) / 1000.0);
				[NSThread sleepForTimeInterval:delay];
			}
		});
	});
});

it(@"should install an update in process", ^{
	SQRLStateManager *stateManager = [[SQRLStateManager alloc] initWithIdentifier:NSRunningApplication.currentApplication.localizedName];
	expect(stateManager).notTo.beNil();

	stateManager.targetBundleURL = self.testApplicationURL;
	stateManager.updateBundleURL = [self createTestApplicationUpdate];
	stateManager.applicationSupportURL = self.temporaryDirectoryURL;
	stateManager.requirementData = self.testApplicationCodeSigningRequirementData;
	stateManager.state = SQRLShipItStateClearingQuarantine;

	SQRLInstaller *installer = [[SQRLInstaller alloc] initWithStateManager:stateManager];
	expect(installer).notTo.beNil();

	NSError *installError = nil;
	BOOL install = [[installer.installUpdateCommand execute:nil] asynchronouslyWaitUntilCompleted:&installError];
	expect(install).to.beTruthy();
	expect(installError).to.beNil();
});

fit(@"should not install an update after too many attempts", ^{
	NSURL *targetURL = self.testApplicationURL;
	NSURL *backupURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app.bak"];
	expect([NSFileManager.defaultManager moveItemAtURL:targetURL toURL:backupURL error:NULL]).to.beTruthy();

	SQRLStateManager *stateManager = [[SQRLStateManager alloc] initWithIdentifier:SQRLShipItLauncher.shipItJobLabel];
	stateManager.targetBundleURL = targetURL;
	stateManager.updateBundleURL = [self createTestApplicationUpdate];
	stateManager.backupBundleURL = backupURL;
	stateManager.applicationSupportURL = self.temporaryDirectoryURL;
	stateManager.requirementData = self.testApplicationCodeSigningRequirementData;
	stateManager.state = SQRLShipItStateInstalling;
	stateManager.installationStateAttempt = 4;
	expect([stateManager synchronize]).to.beTruthy();

	__block NSError *error = nil;
	SQRLXPCObject *connection = [[SQRLShipItLauncher launchPrivileged:NO] firstOrDefault:nil success:NULL error:&error];
	expect(connection).notTo.beNil();

	xpc_connection_set_event_handler(connection.object, ^(xpc_object_t event) {});

	// Send ShipIt a blank command just to start it up.
	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(message, SQRLShipItCommandKey, "");

	xpc_connection_send_message(connection.object, message);
	xpc_release(message);

	xpc_connection_send_barrier(connection.object, ^{
		xpc_connection_cancel(connection.object);
	});

	[NSThread sleepForTimeInterval:0.2];

	// No update should've been installed, and the application should've been
	// restored from the backup.
	expect([[self.testApplicationVerifier verifyCodeSignatureOfBundle:targetURL] waitUntilCompleted:&error]).to.beTruthy();
	expect(error).to.beNil();

	expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
});

SpecEnd
