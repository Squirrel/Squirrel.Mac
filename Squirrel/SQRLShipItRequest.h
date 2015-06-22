//
//  SQRLShipItRequest.h
//  Squirrel
//
//  Created by Keith Duncan on 08/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import <Mantle/Mantle.h>

@class RACSignal;

// The domain for errors originating within `SQRLShipItRequest`.
extern NSString * const SQRLShipItRequestErrorDomain;

// Errors originating from the `SQRLShipItRequestErrorDomain`.
//
// SQRLShipItRequestErrorMissingRequiredProperty - A required property was `nil`
//                                                 upon initialization.
//
//                                                 The `userInfo` dictionary for
//                                                 this error will contain
//                                                 `SQRLShipItStatePropertyErrorKey`.
//
// SQRLShipItRequestErrorUnarchiving             - The saved request could not
//                                                 be unarchived, possibly
//                                                 because it's invalid.
//
// SQRLShipItRequestErrorArchiving               - The request object could not
//                                                 be archived.
typedef enum : NSInteger {
	SQRLShipItRequestErrorMissingRequiredProperty = 1,
	SQRLShipItRequestErrorUnarchiving = 2,
	SQRLShipItRequestErrorArchiving = 3,
} SQRLShipItRequestError;

// Associated with an `NSString` indicating the required property key that did
// not have a value upon initialization.
extern NSString * const SQRLShipItRequestPropertyErrorKey;

// Constructed and written to disk for `ShipIt` to pick up. This represents a
// single update request from the client's perspective.
@interface SQRLShipItRequest : MTLModel

// Reads a `SQRLShipItState` from disk, at the location specified by the given
// URL signal.
//
// URLSignal - Determines the file location to read from, the signal should send
//             an `NSURL` object then complete, or error. This must not be nil.
//
// Returns a signal which will synchronously send a `SQRLShipItRequest` then
// complete, or error.
+ (RACSignal *)readUsingURL:(RACSignal *)URLSignal;

// Writes the receiver to disk, at the location specified by the given URL
// signal.
//
// URLSignal - Determines the file location to write to. The signal should send
//             an `NSURL` object then complete, or error. This must not be nil.
//
// Returns a signal which will synchronously complete or error.
- (RACSignal *)writeUsingURL:(RACSignal *)URLSignal;

// Designated initialiser.
//
// updateBundleURL         - The update bundle which will replace
//                           targetBundleURL. Must not be nil.
// targetBundleURL         - Where the update should be installed, if a bundle
//                           is already present, the update is checked for
//                           suitability against this bundle. Must not be nil.
// bundleIdentifier        - The bundle identifier that the installer should
//                           wait for instances of to terminate before
//                           installing. Can be nil.
// launchAfterInstallation - Whether the updated application should be launched
//                           after installation.
// useUpdateBundleName     - Should the target use the update bundle's name?
//
// Returns a request which can be written to disk for ShipIt to read and
// perform.
- (instancetype)initWithUpdateBundleURL:(NSURL *)updateBundleURL targetBundleURL:(NSURL *)targetBundleURL bundleIdentifier:(NSString *)bundleIdentifier launchAfterInstallation:(BOOL)launchAfterInstallation useUpdateBundleName:(BOOL)useUpdateBundleName;

// The URL to the downloaded update's app bundle.
@property (nonatomic, copy, readonly) NSURL *updateBundleURL;

// The URL to the app bundle that should be replaced with the update.
@property (nonatomic, copy, readonly) NSURL *targetBundleURL;

// The bundle identifier of the application being updated.
//
// If not nil, the installer will wait for applications matching this identifier
// (and `targetBundleURL`) to terminate before continuing.
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;

// Whether to launch the application after an update is successfully installed.
@property (nonatomic, assign, readonly) BOOL launchAfterInstallation;

// Whether the app should use the update bundle's name.
@property (nonatomic, assign, readonly) BOOL useUpdateBundleName;

@end
