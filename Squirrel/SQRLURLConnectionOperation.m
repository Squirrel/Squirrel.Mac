//
//  SQRLURLConnectionOperation.m
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLURLConnectionOperation.h"

#import "EXTKeyPathCoding.h"

@interface SQRLURLConnectionOperation () <NSURLConnectionDataDelegate>
@property (atomic, assign) BOOL isExecuting;
@property (atomic, assign) BOOL isFinished;

// Request the operation was initialised with
@property (nonatomic, copy, readonly) NSURLRequest *request;

// Serial queue for managing operation state
@property (nonatomic, strong, readonly) NSOperationQueue *controlQueue;

// Connection for the request the operation was initialised with
@property (nonatomic, strong) NSURLConnection *connection;

// Latest response received from the connection
@property (nonatomic, strong) NSURLResponse *response;
// Ongoing accumumlated data from the connection
@property (nonatomic, strong) NSMutableData *bodyData;

@property (readwrite, copy, atomic) SQRLResponseProvider responseProvider;
@end

@implementation SQRLURLConnectionOperation

- (instancetype)initWithRequest:(NSURLRequest *)request {
	NSParameterAssert(request != nil);

	self = [self init];
	if (self == nil) return nil;

	_request = [request copy];

	_controlQueue = [[NSOperationQueue alloc] init];
	_controlQueue.maxConcurrentOperationCount = 1;
	_controlQueue.name = @"com.github.Squirrel.connection.control";

	_responseProvider = [^ NSData * (NSURLResponse **responseRef, NSError **errorRef) {
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
		return nil;
	} copy];

	return self;
}

#pragma mark Operation

- (BOOL)isConcurrent {
	return YES;
}

- (void)start {
	[self.controlQueue addOperationWithBlock:^{
		if (self.isCancelled) {
			[self finish];
			return;
		}

		[self willChangeValueForKey:@keypath(self, isExecuting)];
		self.isExecuting = YES;
		[self didChangeValueForKey:@keypath(self, isExecuting)];

		[self startConnection];
	}];
}

- (void)cancel {
	[self.controlQueue addOperationWithBlock:^{
		if (self.connection != nil) {
			[self.connection cancel];
			[self finish];
		}

		[super cancel];
	}];

	[super cancel];
}

- (void)finish {
	[self willChangeValueForKey:@keypath(self, isExecuting)];
	self.isExecuting = NO;
	[self didChangeValueForKey:@keypath(self, isExecuting)];

	[self willChangeValueForKey:@keypath(self, isFinished)];
	self.isFinished = YES;
	[self didChangeValueForKey:@keypath(self, isFinished)];
}

#pragma mark Connection

- (void)startConnection {
	self.connection = [[NSURLConnection alloc] initWithRequest:self.request delegate:self startImmediately:NO];
	self.connection.delegateQueue = self.controlQueue;
	[self.connection start];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	self.responseProvider = ^ NSData * (NSURLResponse **responseRef, NSError **errorRef) {
		if (errorRef != NULL) *errorRef = error;
		return nil;
	};
	[self finish];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	self.response = response;
	self.bodyData = nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	if (self.bodyData == nil) {
		long long expectedSize = self.response.expectedContentLength;
		self.bodyData = [NSMutableData dataWithCapacity:(expectedSize != NSURLResponseUnknownLength ? expectedSize : 0)];
	}

	[self.bodyData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	NSURLResponse *response = self.response;
	NSData *bodyData = self.bodyData;

	self.responseProvider = ^ NSData * (NSURLResponse **responseRef, NSError **errorRef) {
		if (responseRef != NULL) *responseRef = response;
		return bodyData;
	};
	[self finish];
}

@end
