//
//  SQRLXPCConnection.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-02.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLXPCConnection.h"
#import "SQRLArguments.h"
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>

NSString * const SQRLXPCErrorDomain = @"SQRLXPCErrorDomain";
NSString * const SQRLXPCMessageErrorKey = @"SQRLXPCMessageErrorKey";

const NSInteger SQRLXPCErrorUnknown = 0;
const NSInteger SQRLXPCErrorConnectionInterrupted = 1;
const NSInteger SQRLXPCErrorConnectionInvalid = 2;
const NSInteger SQRLXPCErrorTerminationImminent = 3;
const NSInteger SQRLXPCErrorReply = 4;

@interface SQRLXPCConnection () {
	RACSubject *_events;
}

// The queue used to serialize XPC events.
@property (nonatomic, readonly) dispatch_queue_t connectionQueue;

// The private scheduler used to serialize XPC event handling and signal
// delivery.
//
// This scheduler targets `connectionQueue`.
@property (nonatomic, strong, readonly) RACScheduler *connectionScheduler;

@end

@implementation SQRLXPCConnection

#pragma mark Lifecycle

- (id)initWithXPCObject:(xpc_connection_t)connection {
	self = [super initWithXPCObject:connection];
	if (self == nil) return nil;

	_events = [[RACSubject subject] setNameWithFormat:@"%@ -events", self];

	_connectionQueue = dispatch_queue_create("com.github.Squirrel.SQRLXPCConnection.queue", DISPATCH_QUEUE_SERIAL);
	_connectionScheduler = [[RACTargetQueueScheduler alloc] initWithName:@"com.github.Squirrel.SQRLXPCConnection.RACScheduler" targetQueue:self.connectionQueue];
	
	xpc_connection_set_target_queue(connection, self.connectionQueue);
	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
		if (event == XPC_ERROR_CONNECTION_INTERRUPTED) return;

		// Intentionally introduce a retain cycle with `self`.
		[self sendEvent:event toSubscriber:_events];

		if (xpc_get_type(event) == XPC_TYPE_ERROR) {
			NSLog(@"Received error: %@", [[SQRLXPCObject alloc] initWithXPCObject:event]);

			[self cancel];

			// When the connection finishes, break the retain cycle.
			xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
			});
		}
	});

	return self;
}

- (void)dealloc {
	[self.connectionScheduler schedule:^{
		[_events sendCompleted];
	}];

	if (_connectionQueue != NULL) {
		xpc_release(_connectionQueue);
		_connectionQueue = NULL;
	}
}

- (void)cancel {
	NSLog(@"Canceling %@: %@", self, NSThread.callStackSymbols);

	[self.connectionScheduler schedule:^{
		[_events sendCompleted];
	}];

	xpc_connection_cancel(self.object);
}

- (void)resume {
	xpc_connection_resume(self.object);
}

- (RACSignal *)autoconnect {
	return [[[[RACSignal
		createSignal:^(id<RACSubscriber> subscriber) {
			RACDisposable *eventsDisposable = [self.events subscribe:subscriber];
			[self resume];

			return [RACDisposable disposableWithBlock:^{
				// Ordering is important here, because we don't want subscribers
				// to receive completion.
				[eventsDisposable dispose];
				[self cancel];
			}];
		}]
		publish]
		autoconnect]
		setNameWithFormat:@"%@ -autoconnect", self];
}

#pragma mark Communication

- (RACSignal *)sendBarrierMessage:(SQRLXPCObject *)message {
	NSParameterAssert(message != nil);

	return [[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			RACDisposable *eventsDisposable = [[self.events ignoreValues] subscribe:subscriber];

			xpc_connection_send_message(self.object, message.object);
			xpc_connection_send_barrier(self.object, ^{
				[subscriber sendCompleted];
			});

			return eventsDisposable;
		}]
		setNameWithFormat:@"%@ -sendBarrierMessage: %@", self, message];
}

- (RACSignal *)sendCommandMessage:(SQRLXPCObject *)commandMessage {
	return [[[[self
		sendMessageExpectingReply:commandMessage] logAll] // SYN
		flattenMap:^(SQRLXPCObject *message) { // SYN-ACK
			xpc_object_t dict = xpc_dictionary_create_reply(message.object);
			if (dict == NULL) {
				NSDictionary *userInfo = @{ SQRLXPCMessageErrorKey: message };
				return [RACSignal error:[NSError errorWithDomain:SQRLXPCErrorDomain code:SQRLXPCErrorReply userInfo:userInfo]];
			}

			SQRLXPCObject *reply = [[SQRLXPCObject alloc] initWithXPCObject:dict];
			xpc_release(dict);

			xpc_dictionary_set_bool(reply.object, SQRLReplySuccessKey, true);
			return [self sendBarrierMessage:reply]; // ACK
			return [[self sendBarrierMessage:reply] logAll]; // ACK
		}]
		setNameWithFormat:@"%@ -sendCommandMessage: %@", self, commandMessage];
}

- (RACSignal *)sendMessageExpectingReply:(SQRLXPCObject *)message {
	NSParameterAssert(message != nil);

	return [[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			xpc_connection_send_message_with_reply(self.object, message.object, self.connectionQueue, ^(xpc_object_t event) {
				[self sendEvent:event toSubscriber:subscriber];
				[subscriber sendCompleted];
			});

			return nil;
		}]
		setNameWithFormat:@"%@ -sendMessageExpectingReply: %@", self, message];
}

- (RACSignal *)waitForBarrier {
	return [[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			xpc_connection_send_barrier(self.object, ^{
				[subscriber sendCompleted];
			});

			return nil;
		}]
		setNameWithFormat:@"%@ -waitForBarrier", self];
}

- (void)sendEvent:(xpc_object_t)event toSubscriber:(id<RACSubscriber>)subscriber {
	if (xpc_get_type(event) == XPC_TYPE_ERROR) {
		[subscriber sendError:[self errorFromXPCError:event]];
		return;
	}
	
	SQRLXPCObject *wrappedEvent = [[SQRLXPCObject alloc] initWithXPCObject:event];
	if (xpc_get_type(event) == XPC_TYPE_DICTIONARY) {
		xpc_object_t success = xpc_dictionary_get_value(event, SQRLReplySuccessKey);
		if (success != NULL && !xpc_bool_get_value(success)) {
			const char *errorStr = xpc_dictionary_get_string(event, SQRLReplyErrorKey);

			NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
			userInfo[SQRLXPCMessageErrorKey] = wrappedEvent;
			if (errorStr != NULL) userInfo[NSLocalizedDescriptionKey] = @(errorStr);

			[subscriber sendError:[NSError errorWithDomain:SQRLXPCErrorDomain code:SQRLXPCErrorReply userInfo:userInfo]];
			return;
		}
	}

	[subscriber sendNext:wrappedEvent];
}

#pragma mark Error Handling

- (NSError *)errorFromXPCError:(xpc_object_t)errorEvent {
	NSParameterAssert(xpc_get_type(errorEvent) == XPC_TYPE_ERROR);

	NSInteger code;
	if (errorEvent == XPC_ERROR_CONNECTION_INTERRUPTED) {
		code = SQRLXPCErrorConnectionInterrupted;
	} else if (errorEvent == XPC_ERROR_CONNECTION_INVALID) {
		code = SQRLXPCErrorConnectionInvalid;
	} else if (errorEvent == XPC_ERROR_TERMINATION_IMMINENT) {
		code = SQRLXPCErrorTerminationImminent;
	} else {
		code = SQRLXPCErrorUnknown;
	}

	const char *description = xpc_dictionary_get_string(errorEvent, XPC_ERROR_KEY_DESCRIPTION);

	NSDictionary *userInfo = nil;
	if (description != NULL) userInfo = @{ NSLocalizedDescriptionKey: @(description) };

	return [NSError errorWithDomain:SQRLXPCErrorDomain code:code userInfo:userInfo];
}

#pragma mark NSObject

- (NSString *)description {
	// xpc_copy_description() seems to crash on 10.7 for some connections, so
	// just print out the pointer.
	return [NSString stringWithFormat:@"<%@: %p>{ object = %p }", self.class, self, self.object];
}

@end
