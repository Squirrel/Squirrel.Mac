//
//  SQRLTestCase.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLTestCase.h"

// The name (without any extension) of the test application fixture.
static NSString * const SQRLTestCaseTestAppFixtureName = @"GitHub.app";

@interface SQRLTestCase ()

// The URL to the temporary directory which contains `temporaryDirectoryURL` and
// all copied fixtures.
@property (nonatomic, copy, readonly) NSURL *baseTemporaryDirectoryURL;

@end

@implementation SQRLTestCase

#pragma mark Properties

@synthesize baseTemporaryDirectoryURL = _baseTemporaryDirectoryURL;

#pragma mark Lifecycle

- (void)SPT_tearDown {
	[NSFileManager.defaultManager removeItemAtURL:_baseTemporaryDirectoryURL error:NULL];
	_baseTemporaryDirectoryURL = nil;
}

#pragma mark Temporary Directory

- (NSURL *)baseTemporaryDirectoryURL {
	if (_baseTemporaryDirectoryURL == nil) {
		NSURL *globalTemporaryDirectory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
		_baseTemporaryDirectoryURL = [globalTemporaryDirectory URLByAppendingPathComponent:[NSProcessInfo.processInfo globallyUniqueString]];
		
		NSError *error = nil;
		BOOL success = [NSFileManager.defaultManager createDirectoryAtURL:_baseTemporaryDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error];
		STAssertTrue(success, @"Couldn't create temporary directory at %@: %@", _baseTemporaryDirectoryURL, error);
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

- (void)unzipMember:(NSString *)memberName fromArchiveAtURL:(NSURL *)zipURL intoDirectory:(NSURL *)destinationDirectory {
	NSParameterAssert(memberName != nil);
	NSParameterAssert(zipURL != nil);
	NSParameterAssert(destinationDirectory != nil);

	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/usr/bin/unzip";
	task.arguments = @[ @"-qq", @"-d", destinationDirectory.path, zipURL.path, [memberName stringByAppendingString:@"/*"] ];
	[task launch];
	[task waitUntilExit];
	
	BOOL success = (task.terminationStatus == 0);
	STAssertTrue(success, @"Couldn't unzip member \"%@\" from %@ into %@", memberName, zipURL, destinationDirectory);
	STAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[destinationDirectory URLByAppendingPathComponent:memberName].path], @"Member \"%@\" from %@ does not exist in %@ after unzipping", memberName, zipURL, destinationDirectory);
}

- (NSURL *)fixturesURL {
	NSURL *fixturesURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"fixtures"];

	NSError *error = nil;
	BOOL success = [NSFileManager.defaultManager createDirectoryAtURL:fixturesURL withIntermediateDirectories:YES attributes:nil error:&error];
	STAssertTrue(success, @"Couldn't create fixtures directory at %@: %@", fixturesURL, error);

	return fixturesURL;
}

- (NSURL *)testAppURL {
	NSURL *testAppURL = [self.fixturesURL URLByAppendingPathComponent:SQRLTestCaseTestAppFixtureName];
	if (![NSFileManager.defaultManager fileExistsAtPath:testAppURL.path]) {
		NSURL *zippedURL = [[NSBundle bundleForClass:self.class] URLForResource:SQRLTestCaseTestAppFixtureName withExtension:@"zip" subdirectory:@"Fixtures"];
		[self unzipMember:SQRLTestCaseTestAppFixtureName fromArchiveAtURL:zippedURL intoDirectory:self.fixturesURL];
	}

	return testAppURL;
}

- (NSURL *)zippedTestAppURL {
	NSString *zippedName = [SQRLTestCaseTestAppFixtureName stringByAppendingString:@".zip"];
	NSURL *testAppURL = [self.fixturesURL URLByAppendingPathComponent:zippedName];
	if (![NSFileManager.defaultManager fileExistsAtPath:testAppURL.path]) {
		NSURL *bundledURL = [[NSBundle bundleForClass:self.class] URLForResource:SQRLTestCaseTestAppFixtureName withExtension:@"zip" subdirectory:@"Fixtures"];
		
		NSError *error = nil;
		BOOL success = [NSFileManager.defaultManager copyItemAtURL:bundledURL toURL:testAppURL error:&error];
		STAssertTrue(success, @"Couldn't copy %@ to %@: %@", bundledURL, testAppURL, error);
	}

	return testAppURL;
}

@end
