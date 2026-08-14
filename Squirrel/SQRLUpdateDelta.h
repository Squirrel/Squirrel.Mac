//
//  SQRLUpdateDelta.h
//  Squirrel
//

#import <Foundation/Foundation.h>
#import <Mantle/Mantle.h>

// A binary delta that turns one specific earlier version of the application
// into the update it accompanies (see SQRLUpdate.delta).
//
// The patch is a Sparkle BinaryDelta container (major version 3 or 4). It is
// only ever applied to the running application when `fromVersion` names its
// CFBundleVersion, and the result must pass the same code signing check as a
// fully downloaded update; otherwise the full update is downloaded instead.
@interface SQRLUpdateDelta : MTLModel <MTLJSONSerializing>

// The CFBundleVersion this delta applies to. Required.
@property (readonly, copy, nonatomic) NSString *fromVersion;

// Where the delta can be downloaded from. Required.
@property (readonly, copy, nonatomic) NSURL *deltaURL;

// The SHA-256 digest of the delta file, as lowercase hex. Required: a delta
// that does not match is never opened.
@property (readonly, copy, nonatomic) NSString *digest;

// The size of the delta file in bytes. Required.
@property (readonly, copy, nonatomic) NSNumber *size;

@end
