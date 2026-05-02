//
//  RACSignal+SQRLTransactionExtensions.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-07.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "RACSignal+SQRLTransactionExtensions.h"

#import <ReactiveObjC/RACDisposable.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

// How long before power assertions time out.
//
// This will not actually affect behavior -- it is used only for logging.
static const CFTimeInterval SQRLTransactionPowerAssertionTimeout = 10;

// Tracks how many concurrent transactions are in progress.
//
// This variable should only be used while SQRLTransactionLock() is held.
static NSUInteger SQRLTransactionCount = 0;

// Updates the behavior for handling termination signals.
//
// func - The new handler for termination signals.
//
// This function should only be used while SQRLTransactionLock() is held.
static void SQRLReplaceSignalHandlers(sig_t func) {
	signal(SIGHUP, func);
	signal(SIGINT, func);
	signal(SIGQUIT, func);
	signal(SIGTERM, func);
}

// Protects access to transaction-related resources.
static NSLock *SQRLTransactionLock(void) {
	static NSLock *lock;
	static dispatch_once_t pred;

	dispatch_once(&pred, ^{
		lock = [[NSLock alloc] init];
		lock.name = @"com.github.Squirrel.SQRLTransactionLock";
	});

	return lock;
}

// Creates a transaction with the given user-friendly text.
static RACDisposable *SQRLCreateTransaction(NSString *name, NSString *description) {
	NSCParameterAssert(name != nil);

	[NSProcessInfo.processInfo disableSuddenTermination];

	IOPMAssertionID powerAssertion;
	IOReturn result = IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventSystemSleep, (__bridge CFStringRef)name, (__bridge CFStringRef)description, NULL, NULL, SQRLTransactionPowerAssertionTimeout, kIOPMAssertionTimeoutActionLog, &powerAssertion);
	if (result != kIOReturnSuccess) {
		NSLog(@"Could not install power assertion: %li", (long)result);
	}

	[SQRLTransactionLock() lock];
	{
		// If this is the first transaction, start ignoring termination signals.
		if (SQRLTransactionCount++ == 0) {
			SQRLReplaceSignalHandlers(SIG_IGN);
		}
	}
	[SQRLTransactionLock() unlock];
	
	return [RACDisposable disposableWithBlock:^{
		[SQRLTransactionLock() lock];
		{
			// If this is the last transaction, restore default signal behavior.
			if (--SQRLTransactionCount == 0) {
				// TODO: Restore signal handlers that existed before our
				// original replacement.
				SQRLReplaceSignalHandlers(SIG_DFL);
			}
		}
		[SQRLTransactionLock() unlock];

		IOReturn result = IOPMAssertionRelease(powerAssertion);
		if (result != kIOReturnSuccess) {
			NSLog(@"Could not release power assertion: %li", (long)result);
		}

		[NSProcessInfo.processInfo enableSuddenTermination];
	}];
}

@implementation RACSignal (SQRLTransactionExtensions)

- (RACSignal *)sqrl_addTransactionWithName:(NSString *)name description:(NSString *)descriptionFormat, ... {
	NSString *description = nil;
	if (descriptionFormat != nil) {
		va_list args;
		va_start(args, descriptionFormat);
		description = [[NSString alloc] initWithFormat:descriptionFormat arguments:args];
		va_end(args);
	}

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACDisposable *transactionDisposable = SQRLCreateTransaction(name, description);
		RACDisposable *subscriptionDisposable = [self subscribe:subscriber];

		return [RACDisposable disposableWithBlock:^{
			[subscriptionDisposable dispose];
			[transactionDisposable dispose];
		}];
	}] setNameWithFormat:@"[%@] -sqrl_addTransactionWithName: %@ description: %@", self.name, name, description];
}

- (RACSignal *)sqrl_addSubscriptionTransactionWithName:(NSString *)name description:(NSString *)descriptionFormat, ... {
	NSString *description = nil;
	if (descriptionFormat != nil) {
		va_list args;
		va_start(args, descriptionFormat);
		description = [[NSString alloc] initWithFormat:descriptionFormat arguments:args];
		va_end(args);
	}

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACDisposable *transactionDisposable = SQRLCreateTransaction(name, description);
		RACDisposable *subscriptionDisposable = [self subscribe:subscriber];
		[transactionDisposable dispose];

		return subscriptionDisposable;
	}] setNameWithFormat:@"[%@] -sqrl_addSubscriptionTransactionWithName: %@ description: %@", self.name, name, description];
}

@end
