//
//  SQRLInstallerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignature.h"
#import "SQRLDirectoryManager.h"
#import "SQRLInstaller.h"
#import "SQRLShipItLauncher.h"
#import "SQRLShipItState.h"
#import "SQRLXPCConnection.h"

SpecBegin(SQRLInstaller)

describe(@"after connecting to ShipIt", ^{
	__block NSURL *updateURL;
	__block SQRLXPCConnection *shipitConnection;
	__block SQRLXPCObject *message;

	beforeEach(^{
		updateURL = [self createTestApplicationUpdate];
		shipitConnection = [self connectToShipIt];

		xpc_object_t dict = xpc_dictionary_create(NULL, NULL, 0);
		message = [[SQRLXPCObject alloc] initWithXPCObject:dict];
		xpc_release(dict);

		xpc_dictionary_set_string(message.object, SQRLShipItCommandKey, SQRLShipItInstallCommand);

		xpc_dictionary_set_string(message.object, SQRLTargetBundleURLKey, self.testApplicationURL.absoluteString.UTF8String);
		xpc_dictionary_set_string(message.object, SQRLUpdateBundleURLKey, updateURL.absoluteString.UTF8String);
		xpc_dictionary_set_bool(message.object, SQRLShouldRelaunchKey, false);

		NSData *requirementData = self.testApplicationCodeSigningRequirementData;
		xpc_dictionary_set_data(message.object, SQRLCodeSigningRequirementKey, requirementData.bytes, requirementData.length);
	});

	it(@"should install an update", ^{
		NSError *error = nil;
		BOOL ready = [[shipitConnection sendCommandMessage:message] waitUntilCompleted:&error];
		expect(ready).to.beTruthy();

		expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	});

	it(@"should install an update and relaunch", ^{
		NSString *bundleIdentifier = @"com.github.Squirrel.TestApplication";
		NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
		expect(apps.count).to.equal(0);

		xpc_dictionary_set_bool(message.object, SQRLShouldRelaunchKey, true);

		NSError *error = nil;
		BOOL ready = [[shipitConnection sendCommandMessage:message] waitUntilCompleted:&error];
		expect(ready).to.beTruthy();

		expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
		expect([NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier].count).will.equal(1);
	});

	it(@"should install an update from another volume", ^{
		NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication 2.1" fromDirectory:updateURL.URLByDeletingLastPathComponent];
		updateURL = [diskImageURL URLByAppendingPathComponent:updateURL.lastPathComponent];

		xpc_dictionary_set_string(message.object, SQRLUpdateBundleURLKey, updateURL.absoluteString.UTF8String);

		NSError *error = nil;
		BOOL ready = [[shipitConnection sendCommandMessage:message] waitUntilCompleted:&error];
		expect(ready).to.beTruthy();

		expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	});

	it(@"should install an update to another volume", ^{
		NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication" fromDirectory:self.testApplicationURL.URLByDeletingLastPathComponent];
		NSURL *targetURL = [diskImageURL URLByAppendingPathComponent:self.testApplicationURL.lastPathComponent];

		xpc_dictionary_set_string(message.object, SQRLTargetBundleURLKey, targetURL.absoluteString.UTF8String);

		NSError *error = nil;
		BOOL ready = [[shipitConnection sendCommandMessage:message] waitUntilCompleted:&error];
		expect(ready).to.beTruthy();

		NSURL *plistURL = [targetURL URLByAppendingPathComponent:@"Contents/Info.plist"];
		expect([NSDictionary dictionaryWithContentsOfURL:plistURL][SQRLBundleShortVersionStringKey]).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	});

	it(@"should not install an update if the connection closes before a final reply", ^{
		NSError *error = nil;
		BOOL ready = [[shipitConnection sendMessageExpectingReply:message] waitUntilCompleted:&error];
		expect(ready).to.beTruthy();

		[shipitConnection cancel];
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
			[shipitConnection.events subscribeError:^(NSError *error) {
				terminated = YES;
			} completed:^{
				terminated = YES;
			}];

			sendMessage = ^{
				NSError *error = nil;
				BOOL ready = [[shipitConnection sendCommandMessage:message] waitUntilCompleted:&error];
				expect(ready).to.beTruthy();

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
			BOOL success = [[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error];
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
	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:[self createTestApplicationUpdate] bundleIdentifier:nil codeSignature:self.testApplicationSignature];
	state.installerState = SQRLInstallerStateClearingQuarantine;

	SQRLInstaller *installer = [[SQRLInstaller alloc] initWithDirectoryManager:SQRLDirectoryManager.currentApplicationManager];
	expect(installer).notTo.beNil();

	NSError *installError = nil;
	BOOL install = [[installer.installUpdateCommand execute:state] asynchronouslyWaitUntilCompleted:&installError];
	expect(install).to.beTruthy();
	expect(installError).to.beNil();
});

it(@"should not install an update after too many attempts", ^{
	NSURL *targetURL = self.testApplicationURL;
	NSURL *backupURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app.bak"];
	expect([NSFileManager.defaultManager moveItemAtURL:targetURL toURL:backupURL error:NULL]).to.beTruthy();

	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:targetURL updateBundleURL:[self createTestApplicationUpdate] bundleIdentifier:nil codeSignature:self.testApplicationSignature];
	state.backupBundleURL = backupURL;
	state.installerState = SQRLInstallerStateInstalling;
	state.installationStateAttempt = 4;
	expect([[state writeUsingDirectoryManager:self.shipItDirectoryManager] waitUntilCompleted:NULL]).to.beTruthy();

	NSError *error = nil;
	SQRLXPCConnection *connection = [[SQRLShipItLauncher launchPrivileged:NO] firstOrDefault:nil success:NULL error:&error];
	expect(connection).notTo.beNil();

	// Send ShipIt a blank command just to start it up.
	xpc_object_t dict = xpc_dictionary_create(NULL, NULL, 0);
	SQRLXPCObject *message = [[SQRLXPCObject alloc] initWithXPCObject:dict];
	xpc_release(dict);

	xpc_dictionary_set_string(message.object, SQRLShipItCommandKey, "");

	BOOL ready = [[connection sendBarrierMessage:message] waitUntilCompleted:&error];
	expect(ready).to.beTruthy();

	[connection cancel];
	[NSThread sleepForTimeInterval:0.2];

	// No update should've been installed, and the application should've been
	// restored from the backup.
	BOOL success = [[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();

	expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
});

SpecEnd
