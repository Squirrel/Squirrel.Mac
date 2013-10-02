//
//  SQRLXPCConnection.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-02.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLXPCConnection.h"
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>

NSString * const SQRLXPCErrorDomain = @"SQRLXPCErrorDomain";
const NSInteger SQRLXPCErrorUnknown = 0;
const NSInteger SQRLXPCErrorConnectionInterrupted = 1;
const NSInteger SQRLXPCErrorConnectionInvalid = 2;
const NSInteger SQRLXPCErrorTerminationImminent = 3;

@interface SQRLXPCConnection () {
	RACSubject *_events;
}

@end

@implementation SQRLXPCConnection

#pragma mark Lifecycle

- (id)initWithXPCObject:(xpc_connection_t)connection {
	self = [super initWithXPCObject:connection];
	if (self == nil) return nil;

	_events = [[RACSubject subject] setNameWithFormat:@"%@ -events", self];

	if (connection != NULL) {
		xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
			// Intentionally introduce a retain cycle with `self`.
			[self sendEvent:event toSubscriber:_events];

			if (xpc_get_type(event) == XPC_TYPE_ERROR) {
				[self cancel];

				// When the connection finishes, break the retain cycle.
				xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
				});
			}
		});
	}

	return self;
}

- (void)dealloc {
	[_events sendCompleted];
}

- (void)cancel {
	[_events sendCompleted];

	if (self.object != NULL) xpc_connection_cancel(self.object);
}

- (void)resume {
	if (self.object != NULL) xpc_connection_resume(self.object);
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

- (RACSignal *)sendMessageExpectingReply:(SQRLXPCObject *)message {
	if (self.object == NULL) return [RACSignal empty];

	return [[[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			xpc_connection_send_message_with_reply(self.object, message.object, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(xpc_object_t event) {
				[self sendEvent:event toSubscriber:subscriber];
				[subscriber sendCompleted];
			});

			return nil;
		}]
		replay]
		setNameWithFormat:@"%@ -sendMessageExpectingReply: %@", self, message];
}

- (void)sendEvent:(xpc_object_t)event toSubscriber:(id<RACSubscriber>)subscriber {
	if (xpc_get_type(event) == XPC_TYPE_ERROR) {
		[subscriber sendError:[self errorFromXPCError:event]];
	} else {
		SQRLXPCObject *wrappedEvent = [[SQRLXPCObject alloc] initWithXPCObject:event];
		[subscriber sendNext:wrappedEvent];
	}
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

@end
