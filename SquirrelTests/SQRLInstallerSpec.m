//
//  SQRLInstallerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Squirrel/Squirrel.h>

#import "SQRLInstaller+Private.h"

SpecBegin(SQRLInstallerSpec)

mode_t (^modeOfURL)(NSURL *) = ^ mode_t (NSURL *fileURL) {
	NSFileSecurity *fileSecurity = nil;
	BOOL success = [fileURL getResourceValue:&fileSecurity forKey:NSURLFileSecurityKey error:NULL];
	expect(success).to.beTruthy();
	expect(fileSecurity).notTo.beNil();

	__block mode_t mode;
	expect(CFFileSecurityGetMode((__bridge CFFileSecurityRef)fileSecurity, &mode)).to.beTruthy();

	return mode & (S_IRWXU | S_IRWXG | S_IRWXO);
};

__block NSURL *updateURL;

beforeEach(^{
	updateURL = [self createTestApplicationUpdate];
});

it(@"should install an update using ShipIt", ^{
	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO];

	[self installWithRequest:request remote:YES];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should install an update in process", ^{
	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO];

	[self installWithRequest:request remote:NO];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should install an update and relaunch", ^{
	NSString *bundleIdentifier = @"com.github.Squirrel.TestApplication";
	NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
	expect(apps.count).to.equal(0);

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:YES];

	[self installWithRequest:request remote:YES];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	expect([NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier].count).will.equal(1);
});

it(@"should install an update from another volume", ^{
	NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication 2.1" fromDirectory:updateURL.URLByDeletingLastPathComponent];
	updateURL = [diskImageURL URLByAppendingPathComponent:updateURL.lastPathComponent];

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO];

	[self installWithRequest:request remote:YES];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should install an update to another volume", ^{
	NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication" fromDirectory:self.testApplicationURL.URLByDeletingLastPathComponent];
	NSURL *targetURL = [diskImageURL URLByAppendingPathComponent:self.testApplicationURL.lastPathComponent];

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:targetURL bundleIdentifier:nil launchAfterInstallation:NO];

	[self installWithRequest:request remote:YES];

	NSURL *plistURL = [targetURL URLByAppendingPathComponent:@"Contents/Info.plist"];
	expect([NSDictionary dictionaryWithContentsOfURL:plistURL][SQRLBundleShortVersionStringKey]).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

describe(@"with backup restoration", ^{
	__block NSURL *targetURL;

	__block SQRLShipItRequest *request;

	beforeEach(^{
		targetURL = self.testApplicationURL;

		request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:targetURL bundleIdentifier:nil launchAfterInstallation:NO];

		NSURL *copiedTargetURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication Target.app"];
		expect([NSFileManager.defaultManager moveItemAtURL:targetURL toURL:copiedTargetURL error:NULL]).to.beTruthy();

		SQRLCodeSignature *codeSignature = self.testApplicationSignature;

		SQRLInstallerOwnedBundle *ownedBundle = [[SQRLInstallerOwnedBundle alloc] initWithOriginalURL:targetURL temporaryURL:copiedTargetURL codeSignature:codeSignature];
		NSData *ownedBundleArchive = [NSKeyedArchiver archivedDataWithRootObject:ownedBundle];
		expect(ownedBundleArchive).notTo.beNil();

		// Set up ShipIt's preferences like it paused in the middle of an
		// installation.
		NSString *applicationIdentifier = self.shipItDirectoryManager.applicationIdentifier;

		CFPreferencesSetValue((__bridge CFStringRef)SQRLShipItInstallationAttemptsKey, (__bridge CFPropertyListRef)@(4), (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
		CFPreferencesSetValue((__bridge CFStringRef)SQRLInstallerOwnedBundleKey, (__bridge CFDataRef)ownedBundleArchive, (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);

		BOOL synchronized = CFPreferencesSynchronize((__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
		expect(synchronized).to.beTruthy();
	});

	afterEach(^{
		__block NSError *error;
		expect([[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error]).will.beTruthy();
		expect(error).to.beNil();

		expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
	});

	it(@"should not install an update after too many attempts", ^{
		[self installWithRequest:request remote:YES];
	});

	it(@"should relaunch even after failing to install an update", ^{
		request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:targetURL bundleIdentifier:nil launchAfterInstallation:YES];

		[self installWithRequest:request remote:YES];

		expect([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.github.Squirrel.TestApplication"].count).will.equal(1);
	});
});

it(@"should disallow writing the updated application except by the owner", ^{
	NSString *command = [NSString stringWithFormat:@"chmod -R 0777 '%@'", updateURL.path];
	expect(system(command.UTF8String)).to.equal(0);

	expect(modeOfURL(updateURL)).to.equal(0777);
	expect(modeOfURL([updateURL URLByAppendingPathComponent:@"Contents/MacOS/TestApplication"])).to.equal(0777);

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO];

	[self installWithRequest:request remote:YES];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);

	expect(modeOfURL(self.testApplicationURL)).to.equal(0755);
	expect(modeOfURL([self.testApplicationURL URLByAppendingPathComponent:@"Contents/MacOS/TestApplication"])).to.equal(0755);
});

describe(@"signal handling", ^{
	__block NSURL *targetURL;

	beforeEach(^{
		// Copied so that we don't recreate the TestApplication bundle by
		// accessing the property.
		targetURL = self.testApplicationURL;

		SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO];

		[self installWithRequest:request remote:YES];

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

		NSError *error;
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
		// a couple times to really test resumption.
		//
		// Two SIGKILL signals means that it'll be launched three times (which
		// matches the maximum number of attempts per state).
		for (int i = 0; i < 2; i++) {
			system("killall -KILL ShipIt");

			// Wait at least for the launchd throttle interval.
			NSTimeInterval delay = 2 + (arc4random_uniform(100) / 1000.0);
			[NSThread sleepForTimeInterval:delay];
		}
	});
});

SpecEnd
