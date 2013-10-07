//
//  SQRLTerminationListener.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-04.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLTerminationListener.h"
#import <ReactiveCocoa/ReactiveCocoa.h>

@interface SQRLTerminationListener ()

@property (nonatomic, copy, readonly) NSURL *bundleURL;
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;

@end

@implementation SQRLTerminationListener

#pragma mark Lifecycle

- (id)initWithURL:(NSURL *)bundleURL bundleIdentifier:(NSString *)bundleID {
	NSParameterAssert(bundleURL != nil);
	NSParameterAssert(bundleID != nil);

	self = [super init];
	if (self == nil) return nil;

	_bundleURL = bundleURL.URLByStandardizingPath;
	_bundleIdentifier = [bundleID copy];

	return self;
}

#pragma mark Termination Listening

- (RACSignal *)waitForTermination {
	return [[[[RACSignal
		defer:^{
			NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:self.bundleIdentifier];
			return [apps.rac_sequence signalWithScheduler:RACScheduler.immediateScheduler];
		}]
		filter:^(NSRunningApplication *application) {
			return [application.bundleURL.URLByStandardizingPath isEqual:self.bundleURL];
		}]
		flattenMap:^(NSRunningApplication *application) {
			return [[self
				waitForTerminationOfProcessIdentifier:application.processIdentifier]
				mapReplace:application];
		}]
		setNameWithFormat:@"%@ -waitForTermination", self];
}

- (RACSignal *)waitForTerminationOfProcessIdentifier:(pid_t)processIdentifier {
	return [[RACSignal
		createSignal:^(id<RACSubscriber> subscriber) {
			dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, processIdentifier, DISPATCH_PROC_EXIT, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));

			dispatch_source_set_registration_handler(source, ^{
				[subscriber sendNext:@(processIdentifier)];
			});

			dispatch_source_set_event_handler(source, ^{
				[subscriber sendCompleted];
			});

			dispatch_resume(source);
			return [RACDisposable disposableWithBlock:^{
				dispatch_source_cancel(source);
				dispatch_release(source);
			}];
		}]
		setNameWithFormat:@"%@ -waitForTerminationOfProcessIdentifier: %i", self, (int)processIdentifier];
}

#pragma mark NSObject

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p>{ bundleURL: %@, bundleIdentifier: %@ }", self.class, self, self.bundleURL, self.bundleIdentifier];
}

@end
