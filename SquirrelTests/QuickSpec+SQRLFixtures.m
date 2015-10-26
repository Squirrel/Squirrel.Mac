//
//  QuickSpec+SQRLFixtures.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "QuickSpec+SQRLFixtures.h"

#import "SQRLCodeSignature.h"
#import "SQRLDirectoryManager.h"
#import "SQRLInstaller.h"
#import "SQRLShipItLauncher.h"
#import "SQRLShipItRequest.h"
#import <ServiceManagement/ServiceManagement.h>
#import <objc/runtime.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"

NSString * const SQRLTestApplicationOriginalShortVersionString = @"1.0";
NSString * const SQRLTestApplicationUpdatedShortVersionString = @"2.1";
NSString * const SQRLBundleShortVersionStringKey = @"CFBundleShortVersionString";

const NSTimeInterval SQRLLongTimeout = 20;

static void SQRLKillAllTestApplications(void) {
	// Forcibly kill all copies of the TestApplication that may be running.
	NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.github.Squirrel.TestApplication"];
	[apps makeObjectsPerformSelector:@selector(forceTerminate)];
}

static void SQRLUncaughtExceptionHandler(NSException *exception) {
	SQRLKillAllTestApplications();

	NSLog(@"Uncaught exception: %@", exception);
	raise(SIGTRAP);
	abort();
}

static void SQRLSignalHandler(int sig) {
	NSLog(@"Backtrace: %@", [NSThread callStackSymbols]);
	fflush(stderr);
	abort();
}

static NSBundle *SQRLTestBundle(void) {
	return [NSBundle bundleWithIdentifier:@"com.github.SquirrelTests"];
}

static NSMutableArray *cleanupBlocks = nil;

// The URL to the temporary directory which contains `temporaryDirectoryURL` and
// all copied test data.
static NSURL *baseTemporaryDirectoryURL = nil;

QuickConfigurationBegin(Fixtures)

+ (void)configure:(Configuration *)configuration {
	NSURL *appSupportURL = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:NULL];
	NSAssert(appSupportURL != nil, @"Could not find Application Support folder");

	NSArray *folders = @[
		@"com.github.Squirrel.TestApplication.ShipIt",
		@"com.github.Squirrel.SquirrelTests.ShipIt",
	];

	RACSequence *URLs = [folders.rac_sequence flattenMap:^(NSString *folder) {
		NSURL *baseURL = [appSupportURL URLByAppendingPathComponent:folder];
		return @[
			[baseURL URLByAppendingPathComponent:@"ShipIt_stdout.log"],
			[baseURL URLByAppendingPathComponent:@"ShipIt_stderr.log"]
		].rac_sequence;
	}];

	[configuration beforeSuite:^{
		signal(SIGILL, &SQRLSignalHandler);
		NSSetUncaughtExceptionHandler(&SQRLUncaughtExceptionHandler);

		cleanupBlocks = [NSMutableArray array];

		for (NSURL *URL in URLs) {
			[NSFileManager.defaultManager createDirectoryAtURL:URL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
			if (![[NSData data] writeToURL:URL atomically:YES]) {
				NSLog(@"Could not touch log file at %@", URL);
			}
		}
	}];

	// We want to run any enqueued cleanup blocks after _and before_ each spec,
	// in case beforeSuites (for example) use the fixtures.
	void (^runCleanupBlocks)(void) = ^{
		// Enumerate backwards, so later resources are cleaned up first.
		for (dispatch_block_t block in cleanupBlocks.reverseObjectEnumerator) {
			block();
		}

		[cleanupBlocks removeAllObjects];
	};

	[configuration beforeEach:^{
		runCleanupBlocks();
	}];

	[configuration afterEach:^{
		runCleanupBlocks();
		SQRLKillAllTestApplications();
	}];
}

QuickConfigurationEnd

@implementation QuickSpec (SQRLFixtures)

#pragma mark Lifecycle

- (void)addCleanupBlock:(dispatch_block_t)block {
	[cleanupBlocks addObject:[block copy]];
}

#pragma mark Temporary Directory

- (NSURL *)baseTemporaryDirectoryURL {
	if (baseTemporaryDirectoryURL == nil) {
		NSURL *globalTemporaryDirectory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
		baseTemporaryDirectoryURL = [[globalTemporaryDirectory URLByAppendingPathComponent:@"com.github.SquirrelTests"] URLByAppendingPathComponent:[NSProcessInfo.processInfo globallyUniqueString]];

		NSError *error = nil;
		BOOL success = [NSFileManager.defaultManager createDirectoryAtURL:baseTemporaryDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error];
		XCTAssertTrue(success, @"Couldn't create temporary directory at %@: %@", baseTemporaryDirectoryURL, error);

		[self addCleanupBlock:^{
			[NSFileManager.defaultManager removeItemAtURL:baseTemporaryDirectoryURL error:NULL];
			baseTemporaryDirectoryURL = nil;
		}];
	}

	return baseTemporaryDirectoryURL;
}

- (NSURL *)temporaryDirectoryURL {
	NSURL *temporaryDirectoryURL = [self.baseTemporaryDirectoryURL URLByAppendingPathComponent:@"per-example"];

	NSError *error = nil;
	BOOL success = [NSFileManager.defaultManager createDirectoryAtURL:temporaryDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error];
	XCTAssertTrue(success, @"Couldn't create temporary directory at %@: %@", temporaryDirectoryURL, error);

	return temporaryDirectoryURL;
}

#pragma mark Fixtures

- (NSURL *)testApplicationURL {
	NSURL *fixtureURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app" isDirectory:YES];
	if (![NSFileManager.defaultManager fileExistsAtPath:fixtureURL.path]) {
		NSURL *bundleURL = [SQRLTestBundle() URLForResource:@"TestApplication" withExtension:@"app"];
		XCTAssertNotNil(bundleURL, @"Couldn't find TestApplication.app in test bundle");

		NSError *error = nil;
		BOOL success = [NSFileManager.defaultManager copyItemAtURL:bundleURL toURL:fixtureURL error:&error];
		XCTAssertTrue(success, @"Couldn't copy %@ to %@: %@", bundleURL, fixtureURL, error);

		NSURL *testAppLog = [fixtureURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"TestApplication.log"];
		[[NSData data] writeToURL:testAppLog atomically:YES];
	}

	return fixtureURL;
}

- (NSBundle *)testApplicationBundle {
	NSURL *fixtureURL = self.testApplicationURL;
	NSBundle *bundle = [NSBundle bundleWithURL:fixtureURL];
	XCTAssertNotNil(bundle, @"Couldn't open bundle at %@", fixtureURL);

	return bundle;
}

- (NSString *)testApplicationBundleVersion {
	NSURL *plistURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app/Contents/Info.plist"];

	NSDictionary *plist = [NSDictionary dictionaryWithContentsOfURL:plistURL];
	if (plist == nil) return nil;

	return plist[SQRLBundleShortVersionStringKey];
}

- (NSRunningApplication *)launchTestApplicationWithEnvironment:(NSDictionary *)environment {
	NSDictionary *configuration = nil;
	if (environment != nil) configuration = @{ NSWorkspaceLaunchConfigurationEnvironment: environment };

	NSError *error = nil;
	NSRunningApplication *app = [NSWorkspace.sharedWorkspace launchApplicationAtURL:self.testApplicationURL options:NSWorkspaceLaunchWithoutAddingToRecents | NSWorkspaceLaunchWithoutActivation | NSWorkspaceLaunchNewInstance | NSWorkspaceLaunchAndHide configuration:configuration error:&error];
	XCTAssertNotNil(app, @"Could not launch app at %@: %@", self.testApplicationURL, error);

	[self addCleanupBlock:^{
		if (!app.terminated) {
			[app terminate];
			[app forceTerminate];
		}

		// Remove ShipIt's launchd job so it doesn't relaunch itself.
		CFErrorRef error = NULL;
		if (!SMJobRemove(kSMDomainUserLaunchd, CFSTR("com.github.Squirrel.TestApplication.ShipIt"), NULL, true, &error)) {
			NSLog(@"Could not remove ShipIt job after tests: %@", error);
			if (error != NULL) CFRelease(error);
		}
	}];

	return app;
}

- (NSURL *)createTestApplicationUpdate {
	NSURL *originalURL = [SQRLTestBundle() URLForResource:@"TestApplication 2.1" withExtension:@"app"];
	XCTAssertNotNil(originalURL, @"Couldn't find TestApplication update in test bundle");

	NSError *error = nil;
	NSURL *updateParentURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:self.baseTemporaryDirectoryURL create:YES error:&error];
	XCTAssertNotNil(updateParentURL, @"Could not create temporary directory for updating: %@", error);

	[self addCleanupBlock:^{
		[NSFileManager.defaultManager removeItemAtURL:updateParentURL error:NULL];
	}];

	NSURL *updateURL = [updateParentURL URLByAppendingPathComponent:originalURL.lastPathComponent isDirectory:YES];
	BOOL success = [NSFileManager.defaultManager copyItemAtURL:originalURL toURL:updateURL error:&error];
	XCTAssertTrue(success, @"Couldn't copy %@ to %@: %@", originalURL, updateURL, error);

	return updateURL;
}

- (id)performWithTestApplicationRequirement:(id (^)(SecRequirementRef requirement))block {
	NSURL *bundleURL = [SQRLTestBundle() URLForResource:@"TestApplication" withExtension:@"app"];
	XCTAssertNotNil(bundleURL, @"Couldn't find TestApplication.app in test bundle");

	SecStaticCodeRef staticCode = NULL;
	OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundleURL, kSecCSDefaultFlags, &staticCode);
	XCTAssertTrue(status == noErr, @"Error creating static code object for %@", bundleURL);

	@onExit {
		if (staticCode != NULL) CFRelease(staticCode);
	};

	SecRequirementRef requirement = NULL;
	status = SecCodeCopyDesignatedRequirement(staticCode, kSecCSDefaultFlags, &requirement);
	XCTAssertTrue(status == noErr, @"Error getting designated requirement of %@", staticCode);

	@onExit {
		if (requirement != NULL) CFRelease(requirement);
	};

	return block(requirement);
}

- (SQRLCodeSignature *)testApplicationSignature {
	NSURL *bundleURL = [SQRLTestBundle() URLForResource:@"TestApplication" withExtension:@"app"];
	XCTAssertNotNil(bundleURL, @"Couldn't find TestApplication.app in test bundle");

	NSError *error = nil;
	SQRLCodeSignature *signature = [SQRLCodeSignature signatureWithBundle:bundleURL error:&error];
	XCTAssertNotNil(signature, @"Error getting signature for bundle at %@: %@", bundleURL, error);

	return signature;
}

- (SQRLDirectoryManager *)shipItDirectoryManager {
	NSString *identifier = SQRLShipItLauncher.shipItJobLabel;
	SQRLDirectoryManager *manager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:identifier];
	XCTAssertNotNil(manager, @"Could not create directory manager for %@", identifier);

	return manager;
}

- (void)installWithRequest:(SQRLShipItRequest *)request remote:(BOOL)remote {
	if (remote) {
		expect(@([[request writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL])).to(beTruthy());

		__block NSError *error = nil;
		expect(@([[SQRLShipItLauncher launchPrivileged:NO] waitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());

		[self addCleanupBlock:^{
			// Remove ShipIt's launchd job so it doesn't relaunch itself.
			SMJobRemove(kSMDomainUserLaunchd, (__bridge CFStringRef)SQRLShipItLauncher.shipItJobLabel, NULL, true, NULL);

			NSError *lookupError;
			NSURL *stateURL = [[self.shipItDirectoryManager shipItStateURL] firstOrDefault:nil success:NULL error:&lookupError];
			expect(stateURL).notTo(beNil());
			expect(lookupError).to(beNil());

			[NSFileManager.defaultManager removeItemAtURL:stateURL error:NULL];
		}];
	} else {
		SQRLInstaller *installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:self.shipItDirectoryManager.applicationIdentifier];
		expect(installer).notTo(beNil());

		NSError *installedError = nil;
		BOOL installed = [[installer.installUpdateCommand execute:request] asynchronouslyWaitUntilCompleted:&installedError];
		expect(@(installed)).to(beTruthy());
		expect(installedError).to(beNil());
	}
}

- (NSURL *)createAndMountDiskImageNamed:(NSString *)name fromDirectory:(NSURL *)directoryURL {
	NSURL *destinationURL = [self.baseTemporaryDirectoryURL URLByAppendingPathComponent:name];
	XCTAssertNotNil(destinationURL, @"Could not create disk image URL for %@", directoryURL);

	NSString *createInvocation;
	if (directoryURL == nil) {
		createInvocation = [NSString stringWithFormat:@"hdiutil create '%@' -fs 'HFS+' -volname '%@' -type SPARSE -size 10m -quiet", destinationURL.path, name];
	} else {
		createInvocation = [NSString stringWithFormat:@"hdiutil create '%@' -fs 'HFS+' -volname '%@' -format UDSP -size 10m -srcfolder '%@' -quiet", destinationURL.path, name, directoryURL.path];
	}

	expect(@(system(createInvocation.UTF8String))).to(equal(@0));

	NSString *mountInvocation = [NSString stringWithFormat:@"hdiutil attach '%@.sparseimage' -noverify -noautofsck -readwrite -quiet", destinationURL.path];
	expect(@(system(mountInvocation.UTF8String))).to(equal(@0));

	NSString *path = [NSString stringWithFormat:@"/Volumes/%@", name];
	[self addCleanupBlock:^{
		NSString *detachInvocation = [NSString stringWithFormat:@"hdiutil detach '%@' -force -quiet", path];
		expect(@(system(detachInvocation.UTF8String))).to(equal(@0));
	}];

	return [NSURL fileURLWithPath:path isDirectory:YES];
}

- (BOOL)isRunningOnTravis {
	return NSProcessInfo.processInfo.environment[@"TRAVIS"] != nil;
}

@end

#pragma clang diagnostic pop
