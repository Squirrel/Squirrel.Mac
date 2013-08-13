//
//  SQRLTestCase.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

// The short version string for the `testApplicationBundle`.
extern NSString * const SQRLTestApplicationOriginalShortVersionString;

// The short version string for an update created with
// `createTestApplicationUpdate`.
extern NSString * const SQRLTestApplicationUpdatedShortVersionString;

// The Info.plist key associated with a bundle's short version string.
extern NSString * const SQRLBundleShortVersionStringKey;

@class SQRLCodeSignatureVerifier;

@interface SQRLTestCase : SPTSenTestCase

// A URL to a temporary directory tests can use.
//
// This directory will be deleted between each example.
@property (nonatomic, copy, readonly) NSURL *temporaryDirectoryURL;

// The URL to a modifiable copy of TestApplication.app.
//
// You can use this if you need to make changes that should later be visible in
// the `testApplicationBundle`, without creating the NSBundle initially.
//
// This URL will be deleted between each example.
@property (nonatomic, copy, readonly) NSURL *testApplicationURL;

// The bundle for a modifiable copy of TestApplication.app.
//
// Note that the bundle will only be read once. NSBundle will not pick up future
// modifications.
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
- (NSRunningApplication *)launchTestApplicationWithEnvironment:(NSDictionary *)environment;

// Reads the short version string from the `testApplicationBundle` on disk, but
// without actually loading the bundle into memory.
//
// This will not create the `testApplicationBundle` if it doesn't already exist.
- (NSString *)testApplicationBundleVersion;

// Creates an update for TestApplication.app by bumping its Info.plist version
// to `SQRLTestApplicationUpdatedShortVersionString`.
//
// Returns the URL of the update bundle. The bundle will be automatically
// deleted at the end of the example.
- (NSURL *)createTestApplicationUpdate;

// Returns a code signature verifier that uses requirements from
// TestApplication.app.
- (SQRLCodeSignatureVerifier *)testApplicationVerifier;

// Returns a serialized SecRequirementRef representing the requirements from
// TestApplication.app.
- (NSData *)testApplicationCodeSigningRequirementData;

// Creates a zip archive with the specified item at the top level.
//
// Returns the URL of the created archive. The archive will be automatically
// deleted at the end of the example.
- (NSURL *)zipItemAtURL:(NSURL *)itemURL;

// Opens and resumes a new XPC connection to the ShipIt service.
//
// Returns the new connection, which will be automatically closed at the end of
// the example.
- (xpc_connection_t)connectToShipIt;

// Fetches any error string from the given XPC object.
- (NSString *)errorFromObject:(xpc_object_t)object;

// Creates a disk image using the contents of the given directory, then mounts it.
//
// Returns the URL to the mounted volume's root directory. The disk image will
// automatically be unmounted and deleted at the end of the example.
- (NSURL *)createAndMountDiskImageOfDirectory:(NSURL *)directoryURL;

@end
