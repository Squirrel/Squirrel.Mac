//
//  SQRLTestCase.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

@interface SQRLTestCase : SPTSenTestCase

// A URL to a temporary directory tests can use.
//
// This directory will be deleted between each example.
@property (nonatomic, copy, readonly) NSURL *temporaryDirectoryURL;

// The URL to the test app fixture, automatically unzipping it if necessary.
//
// This URL will be deleted between each spec.
@property (nonatomic, copy, readonly) NSURL *testAppURL;

// The URL to the zipped test app fixture.
//
// This URL will be deleted between each spec.
@property (nonatomic, copy, readonly) NSURL *zippedTestAppURL;

@end
