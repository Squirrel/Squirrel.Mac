//
//  SQRLTestCase.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLTestCase.h"

#import "SQRLCodeSignature.h"
#import "SQRLDirectoryManager.h"
#import "SQRLShipItConnection.h"
#import "SQRLInstaller.h"
#import "SQRLShipItLauncher.h"
#import "SQRLShipItRequest.h"
#import "SQRLTestHelper.h"
#import <ServiceManagement/ServiceManagement.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"

NSString * const SQRLTestApplicationOriginalShortVersionString = @"1.0";
NSString * const SQRLTestApplicationUpdatedShortVersionString = @"2.1";
NSString * const SQRLBundleShortVersionStringKey = @"CFBundleShortVersionString";

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

@interface SQRLTestCase ()

// An array of dispatch_block_t values, for performing cleanup after the current
// example finishes.
//
// This array will be emptied between each example.
@property (nonatomic, strong, readonly) NSMutableArray *exampleCleanupBlocks;

// The URL to the temporary directory which contains `temporaryDirectoryURL` and
// all copied test data.
@property (nonatomic, copy, readonly) NSURL *baseTemporaryDirectoryURL;

// Returns an _unlaunched_ task that will follow log files at the given paths,
// then pipe that output through this process.
+ (NSTask *)tailTaskWithPaths:(RACSequence *)paths;

@end

@implementation SQRLTestCase

#pragma mark Properties

@synthesize baseTemporaryDirectoryURL = _baseTemporaryDirectoryURL;

#pragma mark Lifecycle

+ (void)load {
	NSURL *appSupportURL = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:NULL];
	NSAssert(appSupportURL != nil, @"Could not find Application Support folder");

	NSArray *folders = @[
		@"com.github.Squirrel.TestApplication.ShipIt",
		@"otest.ShipIt",
		@"otest-x86_64.ShipIt",
	];

	RACSequence *URLs = [folders.rac_sequence flattenMap:^(NSString *folder) {
		NSURL *baseURL = [appSupportURL URLByAppendingPathComponent:folder];
		return @[
			[baseURL URLByAppendingPathComponent:@"ShipIt_stdout.log"],
			[baseURL URLByAppendingPathComponent:@"ShipIt_stderr.log"]
		].rac_sequence;
	}];

	for (NSURL *URL in URLs) {
		[[NSData data] writeToURL:URL atomically:YES];
	}

	RACSequence *paths = [URLs map:^(NSURL *URL) {
		return URL.path;
	}];

	NSTask *readShipIt = [self tailTaskWithPaths:paths];
	[readShipIt launch];

	NSAssert([readShipIt isRunning], @"Could not start task %@", readShipIt);

	atexit_b(^{
		[readShipIt terminate];
	});
}

- (void)setUp {
	[super setUp];

	signal(SIGILL, &SQRLSignalHandler);
	NSSetUncaughtExceptionHandler(&SQRLUncaughtExceptionHandler);

	Expecta.asynchronousTestTimeout = 3;
}

- (void)tearDown {
	[super tearDown];

	SQRLKillAllTestApplications();
}

- (void)addCleanupBlock:(dispatch_block_t)block {
	[SQRLTestHelper addCleanupBlock:block];
}

#pragma mark Logging

+ (NSTask *)tailTaskWithPaths:(RACSequence *)paths {
	NSPipe *outputPipe = [NSPipe pipe];
	NSFileHandle *outputHandle = outputPipe.fileHandleForReading;

	outputHandle.readabilityHandler = ^(NSFileHandle *handle) {
		NSString *output = [[NSString alloc] initWithData:handle.availableData encoding:NSUTF8StringEncoding];
		NSLog(@"\n%@", output);
	};

	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/usr/bin/tail";
	task.standardOutput = outputPipe;
	task.arguments = [[paths startWith:@"-f"] array];
	return task;
}

#pragma mark Temporary Directory

- (NSURL *)baseTemporaryDirectoryURL {
	if (_baseTemporaryDirectoryURL == nil) {
		NSURL *globalTemporaryDirectory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
		_baseTemporaryDirectoryURL = [[globalTemporaryDirectory URLByAppendingPathComponent:@"com.github.SquirrelTests"] URLByAppendingPathComponent:[NSProcessInfo.processInfo globallyUniqueString]];

		NSError *error = nil;
		BOOL success = [NSFileManager.defaultManager createDirectoryAtURL:_baseTemporaryDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error];
		XCTAssertTrue(success, @"Couldn't create temporary directory at %@: %@", _baseTemporaryDirectoryURL, error);

		[self addCleanupBlock:^{
			[NSFileManager.defaultManager removeItemAtURL:_baseTemporaryDirectoryURL error:NULL];
			_baseTemporaryDirectoryURL = nil;
		}];
	}

	return _baseTemporaryDirectoryURL;
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
		NSURL *bundleURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication" withExtension:@"app"];
		XCTAssertNotNil(bundleURL, @"Couldn't find TestApplication.app in test bundle");

		NSError *error = nil;
		BOOL success = [NSFileManager.defaultManager copyItemAtURL:bundleURL toURL:fixtureURL error:&error];
		XCTAssertTrue(success, @"Couldn't copy %@ to %@: %@", bundleURL, fixtureURL, error);

		NSURL *testAppLog = [fixtureURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"TestApplication.log"];
		[[NSData data] writeToURL:testAppLog atomically:YES];

		NSTask *readTestApp = [self.class tailTaskWithPaths:[RACSequence return:testAppLog.path]];
		[readTestApp launch];

		XCTAssertTrue([readTestApp isRunning], @"Could not start task %@ to read %@", readTestApp, testAppLog);

		[self addCleanupBlock:^{
			[readTestApp terminate];
		}];
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
	NSURL *originalURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication 2.1" withExtension:@"app"];
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
	NSURL *bundleURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication" withExtension:@"app"];
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
	NSURL *bundleURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication" withExtension:@"app"];
	XCTAssertNotNil(bundleURL, @"Couldn't find TestApplication.app in test bundle");

	NSError *error = nil;
	SQRLCodeSignature *signature = [SQRLCodeSignature signatureWithBundle:bundleURL error:&error];
	XCTAssertNotNil(signature, @"Error getting signature for bundle at %@: %@", bundleURL, error);

	return signature;
}

- (SQRLDirectoryManager *)shipItDirectoryManager {
	NSString *identifier = SQRLShipItConnection.shipItJobLabel;
	SQRLDirectoryManager *manager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:identifier];
	XCTAssertNotNil(manager, @"Could not create directory manager for %@", identifier);

	return manager;
}

- (void)installWithRequest:(SQRLShipItRequest *)request remote:(BOOL)remote {
	if (remote) {
		SQRLShipItConnection *connection = [[SQRLShipItConnection alloc] initWithRootPrivileges:NO];

		__block NSError *error = nil;
		expect([[connection sendRequest:request] waitUntilCompleted:&error]).to.beTruthy();
		expect(error).to.beNil();

		[self addCleanupBlock:^{
			// Remove ShipIt's launchd job so it doesn't relaunch itself.
			SMJobRemove(kSMDomainUserLaunchd, (__bridge CFStringRef)SQRLShipItConnection.shipItJobLabel, NULL, true, NULL);

			NSError *lookupError;
			NSURL *stateURL = [[self.shipItDirectoryManager shipItStateURL] firstOrDefault:nil success:NULL error:&lookupError];
			expect(stateURL).notTo.beNil();
			expect(lookupError).to.beNil();

			[NSFileManager.defaultManager removeItemAtURL:stateURL error:NULL];
		}];
	} else {
		SQRLInstaller *installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:self.shipItDirectoryManager.applicationIdentifier];
		expect(installer).notTo.beNil();

		NSError *installedError = nil;
		BOOL installed = [[installer.installUpdateCommand execute:request] asynchronouslyWaitUntilCompleted:&installedError];
		expect(installed).to.beTruthy();
		expect(installedError).to.beNil();
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

	expect(system(createInvocation.UTF8String)).to.equal(0);

	NSString *mountInvocation = [NSString stringWithFormat:@"hdiutil attach '%@.sparseimage' -noverify -noautofsck -readwrite -quiet", destinationURL.path];
	expect(system(mountInvocation.UTF8String)).to.equal(0);

	NSString *path = [NSString stringWithFormat:@"/Volumes/%@", name];
	[self addCleanupBlock:^{
		NSString *detachInvocation = [NSString stringWithFormat:@"hdiutil detach '%@' -force -quiet", path];
		expect(system(detachInvocation.UTF8String)).to.equal(0);
	}];

	return [NSURL fileURLWithPath:path isDirectory:YES];
}

@end

#pragma clang diagnostic pop
