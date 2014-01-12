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
#import "SQRLShipItConnection.h"
#import "SQRLShipItState.h"

SpecBegin(SQRLInstaller)

__block NSURL *updateURL;

beforeEach(^{
	updateURL = [self createTestApplicationUpdate];
});

it(@"should install an update", ^{
	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil codeSignature:self.testApplicationSignature];

	[self launchShipItWithRequest:state];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should install an update and relaunch", ^{
	NSString *bundleIdentifier = @"com.github.Squirrel.TestApplication";
	NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
	expect(apps.count).to.equal(0);

	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil codeSignature:self.testApplicationSignature];
	state.relaunchAfterInstallation = YES;

	[self launchShipItWithRequest:state];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	expect([NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier].count).will.equal(1);
});

it(@"should install an update from another volume", ^{
	NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication 2.1" fromDirectory:updateURL.URLByDeletingLastPathComponent];
	updateURL = [diskImageURL URLByAppendingPathComponent:updateURL.lastPathComponent];

	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil codeSignature:self.testApplicationSignature];

	[self launchShipItWithRequest:state];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should install an update to another volume", ^{
	NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication" fromDirectory:self.testApplicationURL.URLByDeletingLastPathComponent];
	NSURL *targetURL = [diskImageURL URLByAppendingPathComponent:self.testApplicationURL.lastPathComponent];

	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:targetURL updateBundleURL:updateURL bundleIdentifier:nil codeSignature:self.testApplicationSignature];

	[self launchShipItWithRequest:state];

	NSURL *plistURL = [targetURL URLByAppendingPathComponent:@"Contents/Info.plist"];
	expect([NSDictionary dictionaryWithContentsOfURL:plistURL][SQRLBundleShortVersionStringKey]).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should install an update in process", ^{
	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil codeSignature:self.testApplicationSignature];
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

	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:targetURL updateBundleURL:updateURL bundleIdentifier:nil codeSignature:self.testApplicationSignature];
	state.backupBundleURL = backupURL;
	state.installerState = SQRLInstallerStateInstalling;
	state.installationStateAttempt = 4;

	[self launchShipItWithRequest:state];

	// No update should've been installed, and the application should be
	// restored from the backup.
	__block NSError *error = nil;
	expect([[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error]).will.beTruthy();
	expect(error).to.beNil();

	expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
});

it(@"should relaunch even after failing to install an update", ^{
	NSURL *targetURL = self.testApplicationURL;
	NSURL *backupURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app.bak"];
	expect([NSFileManager.defaultManager moveItemAtURL:targetURL toURL:backupURL error:NULL]).to.beTruthy();

	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:targetURL updateBundleURL:updateURL bundleIdentifier:nil codeSignature:self.testApplicationSignature];
	state.backupBundleURL = backupURL;
	state.installerState = SQRLInstallerStateInstalling;
	state.installationStateAttempt = 4;
	state.relaunchAfterInstallation = YES;

	[self launchShipItWithRequest:state];

	__block NSError *error = nil;
	expect([[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error]).will.beTruthy();
	expect(error).to.beNil();

	expect([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.github.Squirrel.TestApplication"].count).will.equal(1);
	expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
});

describe(@"signal handling", ^{
	__block NSURL *targetURL;

	beforeEach(^{
		// Copied so that we don't recreate the TestApplication bundle by
		// accessing the property.
		targetURL = self.testApplicationURL;

		SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil codeSignature:self.testApplicationSignature];

		[self launchShipItWithRequest:state];

		// Wait until ShipIt has transitioned by at least one state.
		expect([[[SQRLShipItState readUsingURL:self.shipItDirectoryManager.shipItStateURL] asynchronousFirstOrDefault:nil success:NULL error:NULL] installerState]).willNot.equal(SQRLInstallerStateNothingToDo);

		// Apply a random delay before sending the termination signal, to
		// fuzz out race conditions.
		NSTimeInterval delay = arc4random_uniform(50) / 1000.0;
		[NSThread sleepForTimeInterval:delay];
	});

	afterEach(^{
		// Wait up to the launchd throttle interval, then verify that ShipIt
		// relaunched and finished installing the update.
		Expecta.asynchronousTestTimeout = 5;
		expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error];
		expect(success).to.beTruthy();
		expect(error).to.beNil();
	});

	it(@"should handle SIGHUP", ^{
		system("killall -HUP ShipIt");
	});

	it(@"should handle SIGTERM", ^{
		system("killall -TERM ShipIt");
	});

	it(@"should handle SIGINT", ^{
		system("killall -INT ShipIt");
	});

	it(@"should handle SIGQUIT", ^{
		system("killall -QUIT ShipIt");
	});

	it(@"should handle SIGKILL", ^{
		// SIGKILL is unique in that it'll always terminate ShipIt, so send it
		// a few times to really test resumption.
		for (int i = 0; i < 3; i++) {
			system("killall -KILL ShipIt");

			// Wait at least for the launchd throttle interval.
			NSTimeInterval delay = 2 + (arc4random_uniform(100) / 1000.0);
			[NSThread sleepForTimeInterval:delay];
		}
	});
});

SpecEnd
