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

@class SQRLCodeSignature;
@class SQRLDirectoryManager;

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

// A code signature with requirements from TestApplication.app.
@property (nonatomic, strong, readonly) SQRLCodeSignature *testApplicationSignature;

// A serialized `SecRequirementRef` representing the requirements from
// TestApplication.app.
@property (nonatomic, copy, readonly) NSData *testApplicationCodeSigningRequirementData;

// A directory manager for finding URLs that apply to ShipIt.
@property (nonatomic, strong, readonly) SQRLDirectoryManager *shipItDirectoryManager;

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

// Submits ShipIt's launchd job to start it up.
- (void)launchShipIt;

// Creates a disk image, then mounts it.
//
// name         - The name of the disk image and the mounted volume. This must
//                not be nil.
// directoryURL - If not nil, a directory whose contents should be added to the
//                disk image.
//
// Returns the URL to the mounted volume's root directory. The disk image will
// automatically be unmounted and deleted at the end of the example.
- (NSURL *)createAndMountDiskImageNamed:(NSString *)name fromDirectory:(NSURL *)directoryURL;

@end
