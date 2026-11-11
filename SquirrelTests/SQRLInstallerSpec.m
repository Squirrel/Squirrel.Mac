//
//  SQRLInstallerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveObjC/ReactiveObjC.h>
#import <Squirrel/Squirrel.h>

#import "SQRLCodeSignature.h"
#import "SQRLDirectoryManager.h"
#import "SQRLInstaller+Private.h"
#import "SQRLInstallerOwnedBundle.h"
#import "SQRLShipItLauncher.h"
#import "SQRLShipItRequest.h"

#import "QuickSpec+SQRLFixtures.h"

#import <sys/xattr.h>
#import <sys/stat.h>
#import <ServiceManagement/ServiceManagement.h>

@interface SQRLInstaller (SQRLTestingHooks)
- (RACSignal *)deleteOwnedBundleAtURL:(NSURL *)bundleURL;
@end

static NSNumber *SQRLTestShipItPID(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	NSDictionary *job = CFBridgingRelease(SMJobCopyDictionary(kSMDomainUserLaunchd, (__bridge CFStringRef)SQRLShipItLauncher.shipItJobLabel));
#pragma clang diagnostic pop
	return job[@"PID"];
}

static void SQRLSignalTestShipIt(int signalNumber) {
	pid_t pid = SQRLTestShipItPID().intValue;
	if (pid > 0) {
		kill(pid, signalNumber);
	} else {
		NSLog(@"Test ShipIt has already exited before signal %d", signalNumber);
	}
}

QuickSpecBegin(SQRLInstallerSpec)

mode_t (^modeOfURL)(NSURL *) = ^ mode_t (NSURL *fileURL) {
	NSFileSecurity *fileSecurity = nil;
	BOOL success = [fileURL getResourceValue:&fileSecurity forKey:NSURLFileSecurityKey error:NULL];
	expect(@(success)).to(beTruthy());
	expect(fileSecurity).notTo(beNil());

	__block mode_t mode;
	expect(@(CFFileSecurityGetMode((__bridge CFFileSecurityRef)fileSecurity, &mode))).to(beTruthy());

	return mode & (S_IRWXU | S_IRWXG | S_IRWXO);
};

__block NSURL *updateURL;

beforeEach(^{
	updateURL = [self createTestApplicationUpdate];
});

it(@"should install an update using ShipIt", ^{
	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];

	[self installWithRequest:request remote:YES];

	expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
});

it(@"should round-trip the owned bundle through CFPreferences", ^{
	SQRLInstaller *installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:self.shipItDirectoryManager.applicationIdentifier];
	SQRLInstallerOwnedBundle *original = [[SQRLInstallerOwnedBundle alloc] initWithOriginalURL:self.testApplicationURL temporaryURL:updateURL codeSignature:self.testApplicationSignature];

	[installer setValue:original forKey:@"ownedBundle"];

	SQRLInstallerOwnedBundle *restored = [installer valueForKey:@"ownedBundle"];
	expect(restored).notTo(beNil());
	expect(restored.originalURL).to(equal(original.originalURL));
	expect(restored.temporaryURL).to(equal(original.temporaryURL));

	[installer setValue:nil forKey:@"ownedBundle"];
	expect([installer valueForKey:@"ownedBundle"]).to(beNil());
});

it(@"should install an update in process", ^{
	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];

	[self installWithRequest:request remote:NO];

	expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
});

describe(@"with SquirrelMacEnableEarlyStaging enabled", ^{
	__block SQRLInstaller *installer;
	__block SQRLShipItRequest *request;

	beforeEach(^{
		NSString *applicationIdentifier = self.shipItDirectoryManager.applicationIdentifier;
		[NSUserDefaults.standardUserDefaults setBool:YES forKey:@"SquirrelMacEnableEarlyStaging"];
		CFPreferencesSetValue(CFSTR("SquirrelMacEnableEarlyStaging"), kCFBooleanTrue, (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		CFPreferencesSynchronize((__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

		installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:applicationIdentifier];
		request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:@"com.github.Squirrel.TestApplication" launchAfterInstallation:NO useUpdateBundleName:NO];
		[self addCleanupBlock:^{
			[NSUserDefaults.standardUserDefaults removeObjectForKey:@"SquirrelMacEnableEarlyStaging"];
			CFPreferencesSetValue(CFSTR("SquirrelMacEnableEarlyStaging"), NULL, (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
			CFPreferencesSetValue(CFSTR("SQRLInstallerPreparedBundlePath"), NULL, (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
			CFPreferencesSetValue(CFSTR("SQRLInstallerPendingCleanup"), NULL, (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
			CFPreferencesSynchronize((__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
			CFPreferencesSynchronize((__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);

			NSURL *candidate = [installer valueForKey:@"preparedBundleURL"];
			if (candidate != nil) [NSFileManager.defaultManager removeItemAtURL:candidate.URLByDeletingLastPathComponent error:NULL];
		}];
	});

	it(@"should prepare while the app runs without replacing it", ^{
		NSRunningApplication *app = [self launchTestApplicationWithEnvironment:nil];
		__block NSError *error = nil;
		expect(@([[installer prepareRequest:request] asynchronouslyWaitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationOriginalShortVersionString));
		expect(@(app.isTerminated)).to(beFalsy());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:updateURL.path])).to(beTruthy());
	});

	it(@"should install the independent snapshot even if the source changes", ^{
		expect(@([[installer prepareRequest:request] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		NSURL *sourceResource = [updateURL URLByAppendingPathComponent:@"Contents/Resources/Credits.rtf"];
		expect(@([@"changed after cloning" writeToURL:sourceResource atomically:YES encoding:NSUTF8StringEncoding error:NULL])).to(beTruthy());
		__block NSError *error = nil;
		expect(@([[installer.installUpdateCommand execute:request] asynchronouslyWaitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
		expect(@([[installer cleanupAfterInstallation] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
	});

	it(@"should freshly verify the prepared candidate at installation", ^{
		expect(@([[installer prepareRequest:request] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		NSURL *candidate = [installer valueForKey:@"preparedBundleURL"];
		expect(@([@"tampered" writeToURL:[candidate URLByAppendingPathComponent:@"Contents/Resources/Credits.rtf"] atomically:YES encoding:NSUTF8StringEncoding error:NULL])).to(beTruthy());
		__block NSError *error = nil;
		expect(@([[installer.installUpdateCommand execute:request] asynchronouslyWaitUntilCompleted:&error])).to(beFalsy());
		expect(error).notTo(beNil());
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationOriginalShortVersionString));
	});

	it(@"should strip ACLs and lock the private staging directory to 0700, re-staging if permissions are loosened", ^{
		NSString *chmodACL = [NSString stringWithFormat:@"/bin/chmod +a 'everyone allow write' '%@'", updateURL.path];
		expect(@(system(chmodACL.UTF8String))).to(equal(@0));

		expect(@([[installer prepareRequest:request] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		NSURL *candidate = [installer valueForKey:@"preparedBundleURL"];
		expect(@(modeOfURL(candidate.URLByDeletingLastPathComponent))).to(equal(@0700));
		expect(@(modeOfURL(candidate) & (S_IWGRP | S_IWOTH))).to(equal(@0));

		NSFileSecurity *security = nil;
		BOOL gotSecurity = [candidate getResourceValue:&security forKey:NSURLFileSecurityKey error:NULL];
		expect(@(gotSecurity)).to(beTruthy());
		acl_t acl = NULL;
		BOOL gotACL = CFFileSecurityCopyAccessControlList((__bridge CFFileSecurityRef)security, &acl);
		expect(@(gotACL)).to(beFalsy());
		expect(@(acl == NULL)).to(beTruthy());

		// Loosening the private parent directory's mode must cause the installer
		// to discard the candidate and stage a fresh one at install time.
		expect(@(chmod(candidate.URLByDeletingLastPathComponent.path.fileSystemRepresentation, 0755))).to(equal(@0));
		expect(@([[installer.installUpdateCommand execute:request] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:candidate.URLByDeletingLastPathComponent.path])).to(beFalsy());
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
		expect(@([[installer cleanupAfterInstallation] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
	});

	it(@"should discard the old candidate for a changed request", ^{
		expect(@([[installer prepareRequest:request] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		NSURL *oldCandidate = [installer valueForKey:@"preparedBundleURL"];
		NSURL *newerUpdateURL = [self createTestApplicationUpdate];
		SQRLShipItRequest *changed = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:newerUpdateURL targetBundleURL:self.testApplicationURL bundleIdentifier:@"com.github.Squirrel.TestApplication" launchAfterInstallation:NO useUpdateBundleName:NO];
		expect(@([[installer prepareRequest:changed] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:oldCandidate.path])).to(beFalsy());
		expect([installer valueForKey:@"preparedRequest"]).to(equal(changed));
	});

	it(@"should recover committed cleanup without rolling back a successful install", ^{
		expect(@([[installer.installUpdateCommand execute:request] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		SQRLInstallerOwnedBundle *committed = [installer valueForKey:@"ownedBundle"];
		expect(committed.cleanupURLs).notTo(beNil());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:committed.temporaryURL.path])).to(beTruthy());
		SQRLInstaller *restarted = [[SQRLInstaller alloc] initWithApplicationIdentifier:self.shipItDirectoryManager.applicationIdentifier];
		expect(@([[restarted abortInstall] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
		expect(@([NSFileManager.defaultManager fileExistsAtPath:committed.temporaryURL.path])).to(beFalsy());
		expect([restarted valueForKey:@"ownedBundle"]).to(beNil());
	});

	it(@"should retain failed cleanup without preventing the next install", ^{
		expect(@([[installer.installUpdateCommand execute:request] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		SQRLInstallerOwnedBundle *committed = [installer valueForKey:@"ownedBundle"];
		NSURL *locked = [committed.temporaryURL URLByAppendingPathComponent:@"Contents/PkgInfo"];
		expect(@(lchflags(locked.fileSystemRepresentation, UF_IMMUTABLE))).to(equal(@0));
		[self addCleanupBlock:^{ lchflags(locked.fileSystemRepresentation, 0); }];
		NSError *error = nil;
		BOOL cleaned = [[installer cleanupAfterInstallation] asynchronouslyWaitUntilCompleted:&error];
		expect(@(cleaned)).to(beFalsy());
		expect(error).notTo(beNil());
		expect([installer valueForKey:@"ownedBundle"]).to(beNil());
		// The unlocked staged bundle should still have been cleaned up even
		// though the locked backup bundle failed to delete.
		expect(@([NSFileManager.defaultManager fileExistsAtPath:updateURL.path])).to(beFalsy());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:committed.temporaryURL.path])).to(beTruthy());

		// A restarted ShipIt running abortInstall after unlocking should drain
		// the remaining pending cleanup path even when ownedBundle is already nil.
		expect(@(lchflags(locked.fileSystemRepresentation, 0))).to(equal(@0));
		SQRLInstaller *restarted = [[SQRLInstaller alloc] initWithApplicationIdentifier:self.shipItDirectoryManager.applicationIdentifier];
		expect(@([[restarted abortInstall] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:committed.temporaryURL.path])).to(beFalsy());

		NSURL *nextUpdate = [self createTestApplicationUpdate];
		SQRLShipItRequest *next = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:nextUpdate targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];
		expect(@([[installer.installUpdateCommand execute:next] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		expect(@([[installer cleanupAfterInstallation] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
	});

	it(@"should acknowledge readiness before termination and prepare a newer request", ^{
		NSRunningApplication *app = [self launchTestApplicationWithEnvironment:nil];
		[self submitShipItRequest:request];
		__block NSError *error = nil;
		expect(@([[request waitForPreparationUsingURL:self.shipItDirectoryManager.shipItStateURL] asynchronouslyWaitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());
		expect(@(app.isTerminated)).to(beFalsy());
		NSURL *newerUpdateURL = [self createTestApplicationUpdate];
		SQRLShipItRequest *changed = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:newerUpdateURL targetBundleURL:self.testApplicationURL bundleIdentifier:@"com.github.Squirrel.TestApplication" launchAfterInstallation:NO useUpdateBundleName:NO];
		expect(@([[changed writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL])).to(beTruthy());
		expect(@([[changed waitForPreparationUsingURL:self.shipItDirectoryManager.shipItStateURL] asynchronouslyWaitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());
		[app forceTerminate];
		[self waitForShipItJobToExitWithLabel:SQRLShipItLauncher.shipItJobLabel];
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
	});

	it(@"should rebuild preparation after the waiting helper is killed", ^{
		NSRunningApplication *app = [self launchTestApplicationWithEnvironment:nil];
		[self submitShipItRequest:request];
		expect(@([[request waitForPreparationUsingURL:self.shipItDirectoryManager.shipItStateURL] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		NSString *applicationIdentifier = self.shipItDirectoryManager.applicationIdentifier;
		NSString *oldPreparedPath = CFBridgingRelease(CFPreferencesCopyValue(CFSTR("SQRLInstallerPreparedBundlePath"), (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost));
		expect(oldPreparedPath).notTo(beNil());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:oldPreparedPath])).to(beTruthy());
		NSNumber *oldPID = SQRLTestShipItPID();
		if (oldPID.intValue <= 0) {
			XCTFail(@"Waiting ShipIt has no process ID");
			return;
		}
		NSURL *stateURL = [self.shipItDirectoryManager.shipItStateURL first];
		[NSFileManager.defaultManager removeItemAtURL:[SQRLShipItRequest preparationStatusURLForStateURL:stateURL] error:NULL];
		expect(@([[request writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL])).to(beTruthy());
		expect(@(kill(oldPID.intValue, SIGKILL))).to(equal(@0));
		expect(@([[request waitForPreparationUsingURL:self.shipItDirectoryManager.shipItStateURL] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
		expect(SQRLTestShipItPID()).notTo(equal(oldPID));
		expect(@([NSFileManager.defaultManager fileExistsAtPath:oldPreparedPath.stringByDeletingLastPathComponent])).to(beFalsy());
		expect(@(app.isTerminated)).to(beFalsy());
		[app forceTerminate];
		[self waitForShipItJobToExitWithLabel:SQRLShipItLauncher.shipItJobLabel];
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
	});

	it(@"should honor earlyStaging on the request even when ShipIt user defaults are unset", ^{
		NSString *applicationIdentifier = self.shipItDirectoryManager.applicationIdentifier;
		[NSUserDefaults.standardUserDefaults removeObjectForKey:@"SquirrelMacEnableEarlyStaging"];
		CFPreferencesSetValue(CFSTR("SquirrelMacEnableEarlyStaging"), NULL, (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		CFPreferencesSynchronize((__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

		NSMutableDictionary *values = [request.dictionaryValue mutableCopy];
		values[@"earlyStaging"] = @YES;
		SQRLShipItRequest *requestWithFlag = [[SQRLShipItRequest alloc] initWithDictionary:values error:NULL];
		expect(requestWithFlag).notTo(beNil());

		NSRunningApplication *app = [self launchTestApplicationWithEnvironment:nil];
		[self submitShipItRequest:requestWithFlag];
		__block NSError *error = nil;
		expect(@([[requestWithFlag waitForPreparationUsingURL:self.shipItDirectoryManager.shipItStateURL] asynchronouslyWaitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());
		[app forceTerminate];
		[self waitForShipItJobToExitWithLabel:SQRLShipItLauncher.shipItJobLabel];
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
	});
});

describe(@"with SquirrelMacEnableDirectContentsWrite enabled", ^{
	beforeEach(^{
		// SQRLInstaller adds the running application's identifier (and that
		// identifier minus a trailing .ShipIt) as search suites, but
		// `[[NSUserDefaults alloc] init]` already includes the host app's
		// domain — so writing via standardUserDefaults is sufficient when
		// running the installer in-process.
		[NSUserDefaults.standardUserDefaults setBool:YES forKey:@"SquirrelMacEnableDirectContentsWrite"];

		[self addCleanupBlock:^{
			[NSUserDefaults.standardUserDefaults removeObjectForKey:@"SquirrelMacEnableDirectContentsWrite"];
		}];
	});

	it(@"should install an update by replacing Contents and leave the .app directory itself untouched", ^{
		const char *xattrName = "com.github.Squirrel.spec-id";
		NSString *marker = NSProcessInfo.processInfo.globallyUniqueString;
		expect(@(setxattr(self.testApplicationURL.fileSystemRepresentation, xattrName, marker.UTF8String, strlen(marker.UTF8String), 0, 0))).to(equal(@0));

		SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];
		[self installWithRequest:request remote:NO];

		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));

		NSMutableData *buf = [NSMutableData dataWithLength:256];
		ssize_t len = getxattr(self.testApplicationURL.fileSystemRepresentation, xattrName, buf.mutableBytes, buf.length, 0, 0);
		expect(@(len)).to(beGreaterThan(@0));
		expect([[NSString alloc] initWithBytes:buf.bytes length:(NSUInteger)len encoding:NSUTF8StringEncoding]).to(equal(marker));
	});
});

it(@"should refuse to install when the target bundle path traverses a symlink", ^{
	NSURL *symlinkURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"symlinked.app"];
	expect(@([NSFileManager.defaultManager createSymbolicLinkAtURL:symlinkURL withDestinationURL:self.testApplicationURL error:NULL])).to(beTruthy());

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:symlinkURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];

	SQRLInstaller *installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:self.shipItDirectoryManager.applicationIdentifier];
	NSError *error = nil;
	BOOL installed = [[installer.installUpdateCommand execute:request] asynchronouslyWaitUntilCompleted:&error];

	expect(@(installed)).to(beFalsy());
	expect(error.domain).to(equal(SQRLInstallerErrorDomain));
	expect(@(error.code)).to(equal(@(SQRLInstallerErrorInvalidState)));
});

it(@"should abort the install if the target application is still running", ^{
	NSRunningApplication *app = [self launchTestApplicationWithEnvironment:nil];
	expect(@(app.isTerminated)).to(beFalsy());

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:@"com.github.Squirrel.TestApplication" launchAfterInstallation:NO useUpdateBundleName:NO];

	SQRLInstaller *installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:self.shipItDirectoryManager.applicationIdentifier];
	NSError *error = nil;
	BOOL installed = [[installer.installUpdateCommand execute:request] asynchronouslyWaitUntilCompleted:&error];

	expect(@(installed)).to(beFalsy());
	expect(error.domain).to(equal(SQRLInstallerErrorDomain));
	expect(@(error.code)).to(equal(@(SQRLInstallerErrorAppStillRunning)));

	expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationOriginalShortVersionString));
});

it(@"should restore a bundle left by an earlier attempt before waiting for the application to quit", ^{
	NSURL *strandedURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"Stranded.app"];
	NSURL *originalURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"Original.app"];
	expect(@([NSFileManager.defaultManager copyItemAtURL:self.testApplicationURL toURL:strandedURL error:NULL])).to(beTruthy());

	SQRLInstallerOwnedBundle *ownedBundle = [[SQRLInstallerOwnedBundle alloc] initWithOriginalURL:originalURL temporaryURL:strandedURL codeSignature:self.testApplicationSignature];
	NSString *applicationIdentifier = self.shipItDirectoryManager.applicationIdentifier;
	CFPreferencesSetValue((__bridge CFStringRef)SQRLInstallerOwnedBundleKey, (__bridge CFDataRef)[NSKeyedArchiver archivedDataWithRootObject:ownedBundle], (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
	expect(@(CFPreferencesSynchronize((__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost))).to(beTruthy());

	NSRunningApplication *app = [self launchTestApplicationWithEnvironment:nil];

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:@"com.github.Squirrel.TestApplication" launchAfterInstallation:NO useUpdateBundleName:NO];
	[self submitShipItRequest:request];

	expect(@([NSFileManager.defaultManager fileExistsAtPath:originalURL.path])).withTimeout(SQRLLongTimeout).toEventually(beTruthy());
	expect(@([NSFileManager.defaultManager fileExistsAtPath:strandedURL.path])).to(beFalsy());
	expect(@(app.isTerminated)).to(beFalsy());

	[app forceTerminate];
	[self waitForShipItJobToExitWithLabel:SQRLShipItLauncher.shipItJobLabel];
	expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
});

it(@"should install an update and relaunch", ^{
	NSString *bundleIdentifier = @"com.github.Squirrel.TestApplication";
	NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
	expect(@(apps.count)).to(equal(@0));

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:YES useUpdateBundleName:NO];

	[self installWithRequest:request remote:YES];

	expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
	expect(@([NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier].count)).withTimeout(SQRLLongTimeout).toEventually(equal(@1));
});

it(@"should install an update from another volume", ^{
	NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication 2.1" fromDirectory:updateURL.URLByDeletingLastPathComponent];
	updateURL = [diskImageURL URLByAppendingPathComponent:updateURL.lastPathComponent];

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];

	[self installWithRequest:request remote:YES];

	expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
});

it(@"should install an update to another volume", ^{
	NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication" fromDirectory:self.testApplicationURL.URLByDeletingLastPathComponent];
	NSURL *targetURL = [diskImageURL URLByAppendingPathComponent:self.testApplicationURL.lastPathComponent];

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:targetURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];

	[self installWithRequest:request remote:YES];

	NSURL *plistURL = [targetURL URLByAppendingPathComponent:@"Contents/Info.plist"];
	expect([NSDictionary dictionaryWithContentsOfURL:plistURL][SQRLBundleShortVersionStringKey]).to(equal(SQRLTestApplicationUpdatedShortVersionString));
});

describe(@"with backup restoration", ^{
	__block NSURL *targetURL;

	beforeEach(^{
		targetURL = self.testApplicationURL;

		NSURL *copiedTargetURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication Target.app"];
		expect(@([NSFileManager.defaultManager moveItemAtURL:targetURL toURL:copiedTargetURL error:NULL])).to(beTruthy());

		SQRLCodeSignature *codeSignature = self.testApplicationSignature;

		SQRLInstallerOwnedBundle *ownedBundle = [[SQRLInstallerOwnedBundle alloc] initWithOriginalURL:targetURL temporaryURL:copiedTargetURL codeSignature:codeSignature];
		NSData *ownedBundleArchive = [NSKeyedArchiver archivedDataWithRootObject:ownedBundle];
		expect(ownedBundleArchive).notTo(beNil());

		// Set up ShipIt's preferences like it paused in the middle of an
		// installation.
		NSString *applicationIdentifier = self.shipItDirectoryManager.applicationIdentifier;

		CFPreferencesSetValue((__bridge CFStringRef)SQRLShipItInstallationAttemptsKey, (__bridge CFPropertyListRef)@(4), (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
		CFPreferencesSetValue((__bridge CFStringRef)SQRLInstallerOwnedBundleKey, (__bridge CFDataRef)ownedBundleArchive, (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);

		BOOL synchronized = CFPreferencesSynchronize((__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
		expect(@(synchronized)).to(beTruthy());
	});

	it(@"should not install an update after too many attempts", ^{
		SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:targetURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];
		[self installWithRequest:request remote:YES];

		__block NSError *error;
		expect(@([[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());

		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationOriginalShortVersionString));
	});

	it(@"should restore the backup on the first attempt when the update is gone", ^{
		NSString *applicationIdentifier = self.shipItDirectoryManager.applicationIdentifier;
		CFPreferencesSetValue((__bridge CFStringRef)SQRLShipItInstallationAttemptsKey, NULL, (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
		expect(@(CFPreferencesSynchronize((__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost))).to(beTruthy());

		NSURL *missingUpdateURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"update.gone/TestApplication.app" isDirectory:YES];
		SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:missingUpdateURL targetBundleURL:targetURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];
		[self installWithRequest:request remote:YES];

		__block NSError *error;
		expect(@([[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationOriginalShortVersionString));
	});

	it(@"should relaunch even after failing to install an update", ^{
		SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:targetURL bundleIdentifier:nil launchAfterInstallation:YES useUpdateBundleName:NO];
		[self installWithRequest:request remote:YES];

		expect(@([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.github.Squirrel.TestApplication"].count)).withTimeout(SQRLLongTimeout).toEventually(equal(@1));

		__block NSError *error;
		expect(@([[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());

		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationOriginalShortVersionString));
	});
});

it(@"should disallow writing the updated application except by the owner", ^{
	NSString *command = [NSString stringWithFormat:@"chmod -R 0777 '%@'", updateURL.path];
	expect(@(system(command.UTF8String))).to(equal(@0));

	expect(@(modeOfURL(updateURL))).to(equal(@0777));
	expect(@(modeOfURL([updateURL URLByAppendingPathComponent:@"Contents/MacOS/TestApplication"]))).to(equal(@0777));

	SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];

	[self installWithRequest:request remote:YES];

	expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));

	expect(@(modeOfURL(self.testApplicationURL))).to(equal(@0755));
	expect(@(modeOfURL([self.testApplicationURL URLByAppendingPathComponent:@"Contents/MacOS/TestApplication"]))).to(equal(@0755));
});

describe(@"signal handling", ^{
	__block NSURL *targetURL;

	void (^verifyUpdate)(void) = ^{
		// Wait up to the launchd throttle interval, then verify that ShipIt
		// relaunched and finished installing the update.
		expect(self.testApplicationBundleVersion).withTimeout(SQRLLongTimeout).toEventually(equal(SQRLTestApplicationUpdatedShortVersionString));

		NSError *error;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error];
		expect(@(success)).to(beTruthy());
		expect(error).to(beNil());
	};

	beforeEach(^{
		// Copied so that we don't recreate the TestApplication bundle by
		// accessing the property.
		targetURL = self.testApplicationURL;

		SQRLShipItRequest *request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];

		// Submit without waiting so the test can signal ShipIt mid-install.
		[self submitShipItRequest:request];

		// Apply a random delay before sending the termination signal, to
		// fuzz out race conditions.
		NSTimeInterval delay = arc4random_uniform(50) / 1000.0;
		[NSThread sleepForTimeInterval:delay];
	});

	it(@"should handle SIGHUP", ^{
		SQRLSignalTestShipIt(SIGHUP);
		verifyUpdate();
	});

	it(@"should handle SIGTERM", ^{
		SQRLSignalTestShipIt(SIGTERM);
		verifyUpdate();
	});

	it(@"should handle SIGINT", ^{
		SQRLSignalTestShipIt(SIGINT);
		verifyUpdate();
	});

	it(@"should handle SIGQUIT", ^{
		SQRLSignalTestShipIt(SIGQUIT);
		verifyUpdate();
	});

	it(@"should handle SIGKILL", ^{
		// SIGKILL is unique in that it'll always terminate ShipIt, so send it
		// a couple times to really test resumption.
		//
		// Two SIGKILL signals means that it'll be launched three times (which
		// matches the maximum number of attempts per state).
		for (int i = 0; i < 2; i++) {
			SQRLSignalTestShipIt(SIGKILL);

			// Wait at least for the launchd throttle interval.
			NSTimeInterval delay = 2 + (arc4random_uniform(100) / 1000.0);
			[NSThread sleepForTimeInterval:delay];
		}

		verifyUpdate();
	});
});

describe(@"-deleteOwnedBundleAtURL:", ^{
	__block SQRLInstaller *installer;
	__block NSURL *parentURL;
	__block NSURL *bundleURL;

	beforeEach(^{
		installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:@"com.github.SquirrelTests"];
		parentURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:NSProcessInfo.processInfo.globallyUniqueString isDirectory:YES];
		bundleURL = [parentURL URLByAppendingPathComponent:@"Test.app" isDirectory:YES];
		expect(@([NSFileManager.defaultManager createDirectoryAtURL:parentURL withIntermediateDirectories:YES attributes:nil error:NULL])).to(beTruthy());
	});

	it(@"should remove the bundle and its parent directory", ^{
		expect(@([NSFileManager.defaultManager createDirectoryAtURL:bundleURL withIntermediateDirectories:YES attributes:nil error:NULL])).to(beTruthy());

		NSError *error = nil;
		BOOL success = [[installer deleteOwnedBundleAtURL:bundleURL] asynchronouslyWaitUntilCompleted:&error];

		expect(@(success)).to(beTruthy());
		expect(error).to(beNil());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:bundleURL.path])).to(beFalsy());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:parentURL.path])).to(beFalsy());
	});

	it(@"should remove the parent directory when the bundle is already gone", ^{
		expect(@([NSFileManager.defaultManager fileExistsAtPath:bundleURL.path])).to(beFalsy());

		NSError *error = nil;
		BOOL success = [[installer deleteOwnedBundleAtURL:bundleURL] asynchronouslyWaitUntilCompleted:&error];

		expect(@(success)).to(beTruthy());
		expect(error).to(beNil());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:parentURL.path])).to(beFalsy());
	});

	it(@"should allow retrying cleanup after the parent directory was removed", ^{
		expect(@([NSFileManager.defaultManager removeItemAtURL:parentURL error:NULL])).to(beTruthy());
		NSError *error = nil;
		BOOL success = [[installer deleteOwnedBundleAtURL:bundleURL] asynchronouslyWaitUntilCompleted:&error];
		expect(@(success)).to(beTruthy());
		expect(error).to(beNil());
	});

	it(@"should report the rmdir errno when the parent directory is not empty", ^{
		expect(@([NSFileManager.defaultManager createDirectoryAtURL:bundleURL withIntermediateDirectories:YES attributes:nil error:NULL])).to(beTruthy());
		NSURL *siblingURL = [parentURL URLByAppendingPathComponent:@"stray-file"];
		expect(@([[NSData data] writeToURL:siblingURL atomically:YES])).to(beTruthy());

		NSError *error = nil;
		BOOL success = [[installer deleteOwnedBundleAtURL:bundleURL] asynchronouslyWaitUntilCompleted:&error];

		expect(@(success)).to(beFalsy());
		expect(error.domain).to(equal(NSPOSIXErrorDomain));
		expect(@(error.code)).to(equal(@(ENOTEMPTY)));
		expect(@([NSFileManager.defaultManager fileExistsAtPath:siblingURL.path])).to(beTruthy());
	});
});

QuickSpecEnd
