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

// The bundle for a modifiable copy of TestApplication.app.
//
// This bundle will be deleted between each example.
@property (nonatomic, copy, readonly) NSBundle *testApplicationBundle;

// Launches a new copy of TestApplication.app from the `testApplicationBundle`.
//
// Invoking this method multiple times will result in multiple running instances
// of the app.
//
// Returns the instance of TestApplication.app that was launched. The app will
// be automatically terminated at the end of the example.
- (NSRunningApplication *)launchTestApplication;

@end
