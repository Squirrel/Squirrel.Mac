//
//  SQRLXPCObject.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-09-29.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// A boxed reference to an `xpc_object_t`.
//
// This class exists only because the NSXPC APIs are not available on 10.7.
@interface SQRLXPCObject : NSObject

// The object that the receiver was initialized with, or `nil`.
//
// This object will be retained until the receiver deallocates.
@property (nonatomic, readonly) xpc_object_t object;

// Initializes an XPC object wrapper.
//
// object - The object to wrap. This may be nil.
- (id)initWithXPCObject:(xpc_object_t)object;

@end
