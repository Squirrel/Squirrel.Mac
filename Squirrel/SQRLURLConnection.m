//
//  SQRLURLConnectionOperation.m
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLURLConnection.h"

#import <ReactiveCocoa/ReactiveCocoa.h>

@interface SQRLURLConnection () <NSURLConnectionDataDelegate>
// Request the operation was initialised with
@property (nonatomic, copy, readonly) NSURLRequest *request;

// Connection for the request the operation was initialised with.
@property (nonatomic, strong) NSURLConnection *connection;

// Latest response received from the connection.
@property (nonatomic, strong) NSURLResponse *currentResponse;
// Ongoing accumumlated data from the connection
@property (nonatomic, strong) NSMutableData *currentBodyData;

// Connection events are sent on this subject.
@property (nonatomic, strong) RACSubject *connectionSubject;
@end

@implementation SQRLURLConnection

+ (RACSignal *)sqrl_sendAsynchronousRequest:(NSURLRequest *)request {
	return [[[self alloc] initWithRequest:request] result];
}

- (instancetype)initWithRequest:(NSURLRequest *)request {
	NSParameterAssert(request != nil);

	self = [self init];
	if (self == nil) return nil;

	_request = [request copy];

	return self;
}

#pragma mark Connection

// Returns a signal which sends a tuple of NSURLResponse, NSData then completes,
// or errors.
- (RACSignal *)result {
	return [RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		self.connectionSubject = [RACSubject subject];
		RACDisposable *subscriptionDisposable = [self.connectionSubject subscribe:subscriber];

		self.connection = [[NSURLConnection alloc] initWithRequest:self.request delegate:self startImmediately:NO];
		self.connection.delegateQueue = [[NSOperationQueue alloc] init];
		[self.connection start];

		RACDisposable *connectionDisposable = [RACDisposable disposableWithBlock:^{
			[self.connection cancel];
		}];

		return [RACCompoundDisposable compoundDisposableWithDisposables:@[ subscriptionDisposable, connectionDisposable ]];
	}];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	[self.connectionSubject sendError:error];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	self.currentResponse = response;
	self.currentBodyData = nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	if (self.currentBodyData == nil) {
		long long expectedSize = self.currentResponse.expectedContentLength;
		self.currentBodyData = [NSMutableData dataWithCapacity:(expectedSize != NSURLResponseUnknownLength ? expectedSize : 0)];
	}

	[self.currentBodyData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	NSURLResponse *response = self.currentResponse;
	NSData *bodyData = self.currentBodyData ?: NSData.data;

	[self.connectionSubject sendNext:RACTuplePack(response, bodyData)];
	[self.connectionSubject sendCompleted];
}

@end
