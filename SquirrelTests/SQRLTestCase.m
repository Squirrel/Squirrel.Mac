//
//  SQRLTestCase.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLTestCase.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"

NSString * const SQRLTestApplicationOriginalShortVersionString = @"1.0";
NSString * const SQRLTestApplicationUpdatedShortVersionString = @"2.1";

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

@end

@implementation SQRLTestCase

#pragma mark Properties

@synthesize baseTemporaryDirectoryURL = _baseTemporaryDirectoryURL;

#pragma mark Lifecycle

- (void)setUp {
	[super setUp];
	
	signal(SIGILL, &SQRLSignalHandler);
	NSSetUncaughtExceptionHandler(&SQRLUncaughtExceptionHandler);
}

- (void)SPT_setUp {
	_exampleCleanupBlocks = [[NSMutableArray alloc] init];

	NSBundle *squirrelBundle = [NSBundle bundleWithIdentifier:@"com.github.Squirrel"];
	NSURL *shipItLog = [squirrelBundle.bundleURL URLByAppendingPathComponent:@"XPCServices/ShipIt.log"];
	[[NSData data] writeToURL:shipItLog atomically:YES];

	NSTask *readShipIt = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/tail" arguments:@[ @"-f", shipItLog.path ]];
	STAssertTrue([readShipIt isRunning], @"Could not start task %@ to read %@", readShipIt, shipItLog);

	[self addCleanupBlock:^{
		[readShipIt terminate];
	}];
}

- (void)SPT_tearDown {
	NSArray *cleanupBlocks = [self.exampleCleanupBlocks copy];
	_exampleCleanupBlocks = nil;

	// Enumerate backwards, so later resources are cleaned up first.
	for (dispatch_block_t block in cleanupBlocks.reverseObjectEnumerator) {
		block();
	}
}

- (void)tearDown {
	[super tearDown];

	SQRLKillAllTestApplications();
}

- (void)addCleanupBlock:(dispatch_block_t)block {
	[self.exampleCleanupBlocks addObject:[block copy]];
}

#pragma mark Temporary Directory

- (NSURL *)baseTemporaryDirectoryURL {
	if (_baseTemporaryDirectoryURL == nil) {
		NSURL *globalTemporaryDirectory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
		_baseTemporaryDirectoryURL = [globalTemporaryDirectory URLByAppendingPathComponent:[NSProcessInfo.processInfo globallyUniqueString]];
		
		NSError *error = nil;
		BOOL success = [NSFileManager.defaultManager createDirectoryAtURL:_baseTemporaryDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error];
		STAssertTrue(success, @"Couldn't create temporary directory at %@: %@", _baseTemporaryDirectoryURL, error);

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
	STAssertTrue(success, @"Couldn't create temporary directory at %@: %@", temporaryDirectoryURL, error);

	return temporaryDirectoryURL;
}

#pragma mark Fixtures

- (NSBundle *)testApplicationBundle {
	NSURL *fixtureURL = [self.baseTemporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app"];
	if (![NSFileManager.defaultManager fileExistsAtPath:fixtureURL.path]) {
		NSURL *bundleURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication" withExtension:@"app"];
		STAssertNotNil(bundleURL, @"Couldn't find TestApplication.app in test bundle");

		NSError *error = nil;
		BOOL success = [NSFileManager.defaultManager copyItemAtURL:bundleURL toURL:fixtureURL error:&error];
		STAssertTrue(success, @"Couldn't copy %@ to %@: %@", bundleURL, fixtureURL, error);
	}

	NSBundle *bundle = [NSBundle bundleWithURL:fixtureURL];
	STAssertNotNil(bundle, @"Couldn't open bundle at %@", fixtureURL);
	
	return bundle;
}

- (NSRunningApplication *)launchTestApplication {
	NSURL *appURL = self.testApplicationBundle.bundleURL;

	NSURL *testAppLog = [appURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"TestApplication.log"];
	[[NSData data] writeToURL:testAppLog atomically:YES];

	NSTask *readTestApp = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/tail" arguments:@[ @"-f", testAppLog.path ]];
	STAssertTrue([readTestApp isRunning], @"Could not start task %@ to read %@", readTestApp, testAppLog);

	[self addCleanupBlock:^{
		[readTestApp terminate];
	}];

	NSError *error = nil;
	NSRunningApplication *app = [NSWorkspace.sharedWorkspace launchApplicationAtURL:appURL options:NSWorkspaceLaunchWithoutAddingToRecents | NSWorkspaceLaunchWithoutActivation | NSWorkspaceLaunchNewInstance | NSWorkspaceLaunchAndHide configuration:nil error:&error];
	STAssertNotNil(app, @"Could not launch app at %@: %@", appURL, error);

	[self addCleanupBlock:^{
		if (!app.terminated) {
			[app terminate];
			[app forceTerminate];
		}
	}];

	return app;
}

- (NSURL *)createTestApplicationUpdate {
	NSURL *originalURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication" withExtension:@"app"];
	STAssertNotNil(originalURL, @"Couldn't find TestApplication.app in test bundle");

	NSError *error = nil;
	NSURL *updateParentURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:self.baseTemporaryDirectoryURL create:YES error:&error];
	STAssertNotNil(updateParentURL, @"Could not create temporary directory for updating: %@", error);

	NSURL *updateURL = [updateParentURL URLByAppendingPathComponent:@"TestApplication.app"];
	BOOL success = [NSFileManager.defaultManager copyItemAtURL:originalURL toURL:updateURL error:&error];
	STAssertTrue(success, @"Couldn't copy %@ to %@: %@", originalURL, updateURL, error);

	NSURL *plistURL = [updateURL URLByAppendingPathComponent:@"Contents/Info.plist"];
	NSMutableDictionary *infoPlist = [[NSDictionary dictionaryWithContentsOfURL:plistURL] mutableCopy];
	STAssertNotNil(infoPlist, @"Could not read Info.plist from %@", plistURL);

	static NSString * const versionStringKey = @"SQRLTestApplicationOriginalShortVersionString";
	STAssertEqualObjects(infoPlist[versionStringKey], SQRLTestApplicationOriginalShortVersionString, @"Unexpected original version in Info.plist: %@", infoPlist);
	infoPlist[versionStringKey] = SQRLTestApplicationUpdatedShortVersionString;

	success = [infoPlist writeToURL:plistURL atomically:YES];
	STAssertTrue(success, @"Could not write updated Info.plist to %@", plistURL);

	return updateURL;
}

- (xpc_connection_t)connectToShipIt {
	xpc_connection_t connection = xpc_connection_create(SQRLShipItServiceLabel, NULL);
	expect(connection).notTo.beNil();
	
	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
		if (xpc_get_type(event) == XPC_TYPE_ERROR) {
			if (event == XPC_ERROR_CONNECTION_INVALID) {
				STFail(@"ShipIt connection failed with error: %s", xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
			}
		}
	});

	[self addCleanupBlock:^{
		xpc_connection_cancel(connection);
		xpc_release(connection);
	}];

	xpc_connection_resume(connection);
	return connection;
}

@end

#pragma clang diagnostic pop
