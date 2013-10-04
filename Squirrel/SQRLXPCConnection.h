//
//  SQRLXPCConnection.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-02.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLXPCObject.h"

// The domain for errors originating within XPC.
extern NSString * const SQRLXPCErrorDomain;

// An unknown XPC error.
extern const NSInteger SQRLXPCErrorUnknown;

// The remote service exited.
extern const NSInteger SQRLXPCErrorConnectionInterrupted;

// The named service could not be found.
extern const NSInteger SQRLXPCErrorConnectionInvalid;

// The program will be exiting soon.
extern const NSInteger SQRLXPCErrorTerminationImminent;

@class RACSignal;

// A boxed and RACified `xpc_connection_t`.
@interface SQRLXPCConnection : SQRLXPCObject

// Sends received events as `SQRLXPCObject`s.
//
// This signal will error if the XPC connection receives an error, or complete
// if the connection is canceled.
@property (nonatomic, strong, readonly) RACSignal *events;

// Initializes the receiver.
//
// This will take over the connection's event handler.
//
// connection - The connection to wrap. This may be `NULL`, in which case the
//              `SQRLXPCConnection` fails to initialize.
//
// Returns a wrapper, or nil if `connection` was `NULL`.
- (id)initWithXPCObject:(xpc_connection_t)connection;

// Cancels the connection.
//
// This will send completed upon `events`.
- (void)cancel;

// Resumes the connection from a suspended state.
- (void)resume;

// Sends the given message across the connection and listens for a reply.
//
// message - The message to send across the connection. This must not be nil.
//
// Returns a signal which will send any reply as a `SQRLXPCObject` then
// complete on a background thread.
- (RACSignal *)sendMessageExpectingReply:(SQRLXPCObject *)message;

// Lazily resumes the receiver and passes through its `events`.
//
// Returns a signal which resumes the connection upon first subscription, then
// sends its events. Whenever all subscriptions to the returned signal are
// disposed, the connection will be canceled.
- (RACSignal *)autoconnect;

@end
