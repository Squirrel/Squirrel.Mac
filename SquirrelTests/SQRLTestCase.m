//
//  SQRLTestCase.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLTestCase.h"
#import "EXTScope.h"
#import "SQRLCodeSignatureVerifier.h"
#import "SQRLShipItLauncher.h"

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

@end

@implementation SQRLTestCase

#pragma mark Properties

@synthesize baseTemporaryDirectoryURL = _baseTemporaryDirectoryURL;

#pragma mark Lifecycle

+ (void)load {
	NSURL *appSupportURL = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:NULL];
	NSAssert(appSupportURL != nil, @"Could not find Application Support folder");

	NSURL *stdoutShipIt = [appSupportURL URLByAppendingPathComponent:@"ShipIt_stdout.log"];
	NSURL *stderrShipIt = [appSupportURL URLByAppendingPathComponent:@"ShipIt_stderr.log"];

	[[NSData data] writeToURL:stdoutShipIt atomically:YES];
	[[NSData data] writeToURL:stderrShipIt atomically:YES];

	NSTask *readShipIt = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/tail" arguments:@[ @"-f", stdoutShipIt.path, stderrShipIt.path ]];
	NSAssert([readShipIt isRunning], @"Could not start task %@ to read %@ and %@", readShipIt, stdoutShipIt, stderrShipIt);

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

- (void)SPT_setUp {
	_exampleCleanupBlocks = [[NSMutableArray alloc] init];
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

- (NSURL *)testApplicationURL {
	NSURL *fixtureURL = [self.baseTemporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app"];
	if (![NSFileManager.defaultManager fileExistsAtPath:fixtureURL.path]) {
		NSURL *bundleURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication" withExtension:@"app"];
		STAssertNotNil(bundleURL, @"Couldn't find TestApplication.app in test bundle");

		NSError *error = nil;
		BOOL success = [NSFileManager.defaultManager copyItemAtURL:bundleURL toURL:fixtureURL error:&error];
		STAssertTrue(success, @"Couldn't copy %@ to %@: %@", bundleURL, fixtureURL, error);

		NSURL *testAppLog = [fixtureURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"TestApplication.log"];
		[[NSData data] writeToURL:testAppLog atomically:YES];

		NSTask *readTestApp = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/tail" arguments:@[ @"-f", testAppLog.path ]];
		STAssertTrue([readTestApp isRunning], @"Could not start task %@ to read %@", readTestApp, testAppLog);

		[self addCleanupBlock:^{
			[readTestApp terminate];
		}];
	}

	return fixtureURL;
}

- (NSBundle *)testApplicationBundle {
	NSURL *fixtureURL = self.testApplicationURL;
	NSBundle *bundle = [NSBundle bundleWithURL:fixtureURL];
	STAssertNotNil(bundle, @"Couldn't open bundle at %@", fixtureURL);
	
	return bundle;
}

- (NSString *)testApplicationBundleVersion {
	NSURL *plistURL = [self.baseTemporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app/Contents/Info.plist"];

	NSDictionary *plist = [NSDictionary dictionaryWithContentsOfURL:plistURL];
	if (plist == nil) return nil;

	return plist[SQRLBundleShortVersionStringKey];
}

- (NSRunningApplication *)launchTestApplicationWithEnvironment:(NSDictionary *)environment {
	NSDictionary *configuration = nil;
	if (environment != nil) configuration = @{ NSWorkspaceLaunchConfigurationEnvironment: environment };

	NSError *error = nil;
	NSRunningApplication *app = [NSWorkspace.sharedWorkspace launchApplicationAtURL:self.testApplicationURL options:NSWorkspaceLaunchWithoutAddingToRecents | NSWorkspaceLaunchWithoutActivation | NSWorkspaceLaunchNewInstance | NSWorkspaceLaunchAndHide configuration:configuration error:&error];
	STAssertNotNil(app, @"Could not launch app at %@: %@", self.testApplicationURL, error);

	[self addCleanupBlock:^{
		if (!app.terminated) {
			[app terminate];
			[app forceTerminate];
		}
	}];

	return app;
}

- (NSURL *)createTestApplicationUpdate {
	NSURL *originalURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication 2.1" withExtension:@"app"];
	STAssertNotNil(originalURL, @"Couldn't find TestApplication update in test bundle");

	NSError *error = nil;
	NSURL *updateParentURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:self.baseTemporaryDirectoryURL create:YES error:&error];
	STAssertNotNil(updateParentURL, @"Could not create temporary directory for updating: %@", error);

	NSURL *updateURL = [updateParentURL URLByAppendingPathComponent:originalURL.lastPathComponent];
	BOOL success = [NSFileManager.defaultManager copyItemAtURL:originalURL toURL:updateURL error:&error];
	STAssertTrue(success, @"Couldn't copy %@ to %@: %@", originalURL, updateURL, error);

	return updateURL;
}

- (id)performWithTestApplicationRequirement:(id (^)(SecRequirementRef requirement))block {
	NSURL *bundleURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication" withExtension:@"app"];
	STAssertNotNil(bundleURL, @"Couldn't find TestApplication.app in test bundle");

	SecStaticCodeRef staticCode = NULL;
	OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundleURL, kSecCSDefaultFlags, &staticCode);
	STAssertTrue(status == noErr, @"Error creating static code object for %@", bundleURL);

	@onExit {
		if (staticCode != NULL) CFRelease(staticCode);
	};

	SecRequirementRef requirement = NULL;
	status = SecCodeCopyDesignatedRequirement(staticCode, kSecCSDefaultFlags, &requirement);
	STAssertTrue(status == noErr, @"Error getting designated requirement of %@", staticCode);

	@onExit {
		if (requirement != NULL) CFRelease(requirement);
	};

	return block(requirement);
}

- (SQRLCodeSignatureVerifier *)testApplicationVerifier {
	return [self performWithTestApplicationRequirement:^(SecRequirementRef requirement) {
		return [[SQRLCodeSignatureVerifier alloc] initWithRequirement:requirement];
	}];
}

- (NSData *)testApplicationCodeSigningRequirementData {
	return [self performWithTestApplicationRequirement:^(SecRequirementRef requirement) {
		CFDataRef data = NULL;
		OSStatus status = SecRequirementCopyData(requirement, kSecCSDefaultFlags, &data);
		STAssertTrue(status == noErr, @"Error copying data for requirement %@", requirement);

		return CFBridgingRelease(data);
	}];
}

- (NSURL *)zipItemAtURL:(NSURL *)itemURL {
	NSURL *outputURL = [[self.baseTemporaryDirectoryURL URLByAppendingPathComponent:itemURL.lastPathComponent] URLByAppendingPathExtension:@"zip"];
	STAssertNotNil(outputURL, @"Could not create zip archive URL for %@", itemURL);

	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/usr/bin/ditto";
	task.currentDirectoryPath = itemURL.URLByDeletingLastPathComponent.path;
	task.arguments = @[ @"-ck", @"--keepParent", itemURL.lastPathComponent, outputURL.path ];
	[task launch];
	[task waitUntilExit];

	STAssertEquals(task.terminationStatus, 0, @"zip task terminated with an error");
	return outputURL;
}

- (xpc_connection_t)connectToShipIt {
	SQRLShipItLauncher *launcher = [[SQRLShipItLauncher alloc] init];

	NSError *error = nil;
	xpc_connection_t connection = [launcher launch:&error];
	STAssertTrue(connection != NULL, @"Could not open XPC connection: %@", error);
	
	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
		if (xpc_get_type(event) == XPC_TYPE_ERROR) {
			if (event == XPC_ERROR_CONNECTION_INVALID) {
				STFail(@"ShipIt connection invalid: %@", [self errorFromObject:event]);
			} else if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
				STFail(@"ShipIt connection interrupted: %@", [self errorFromObject:event]);
			}
		}
	});

	[self addCleanupBlock:^{
		xpc_connection_cancel(connection);
	}];

	xpc_connection_resume(connection);
	return connection;
}

- (NSURL *)createAndMountDiskImageOfDirectory:(NSURL *)directoryURL {
	NSString *name = directoryURL.lastPathComponent;
	NSURL *destinationURL = [[self.baseTemporaryDirectoryURL URLByAppendingPathComponent:name] URLByAppendingPathExtension:@"dmg"];
	STAssertNotNil(destinationURL, @"Could not create disk image URL for %@", directoryURL);

	NSString *createInvocation = [NSString stringWithFormat:@"hdiutil create '%@' -fs 'HFS+' -format UDRW -volname '%@' -srcfolder '%@' -quiet", destinationURL.path, name, directoryURL.path];
	expect(system(createInvocation.UTF8String)).to.equal(0);

	NSString *mountInvocation = [NSString stringWithFormat:@"hdiutil attach '%@' -noverify -noautofsck -readwrite -quiet", destinationURL.path];
	expect(system(mountInvocation.UTF8String)).to.equal(0);

	NSString *path = [NSString stringWithFormat:@"/Volumes/%@", name];
	[self addCleanupBlock:^{
		NSString *detachInvocation = [NSString stringWithFormat:@"hdiutil detach '%@' -force -quiet", path];
		expect(system(detachInvocation.UTF8String)).to.equal(0);
	}];

	return [NSURL fileURLWithPath:path isDirectory:YES];
}

#pragma mark Diagnostics

- (NSString *)errorFromObject:(xpc_object_t)object {
	const char *desc = NULL;

	if (xpc_get_type(object) == XPC_TYPE_ERROR) {
		desc = xpc_dictionary_get_string(object, XPC_ERROR_KEY_DESCRIPTION);
	} else if (xpc_get_type(object) == XPC_TYPE_DICTIONARY) {
		desc = xpc_dictionary_get_string(object, SQRLShipItErrorKey);
	}

	if (desc == NULL) return nil;
	return @(desc);
}

@end

#pragma clang diagnostic pop
