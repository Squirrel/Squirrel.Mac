//
//  SQRLTerminationListenerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-07.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Squirrel/Squirrel.h>

#import "SQRLTerminationListener.h"

#import "QuickSpec+SQRLFixtures.h"

QuickSpecBegin(SQRLTerminationListenerSpec)

__block SQRLTerminationListener *listener;

beforeEach(^{
	listener = [[SQRLTerminationListener alloc] initWithURL:self.testApplicationURL bundleIdentifier:self.testApplicationBundle.bundleIdentifier];
	expect(listener).notTo(beNil());
});

it(@"should complete immediately when the app is not running", ^{
	__block BOOL completed = NO;
	[[listener waitForTermination] subscribeCompleted:^{
		completed = YES;
	}];

	expect(@(completed)).to(beTruthy());
});

it(@"should wait until one instance terminates", ^{
	SKIP_IF_RUNNING_ON_TRAVIS

	NSRunningApplication *app = [self launchTestApplicationWithEnvironment:nil];

	__block NSRunningApplication *observedApp = nil;
	__block BOOL completed = NO;
	[[listener waitForTermination] subscribeNext:^(id x) {
		observedApp = x;
	} completed:^{
		completed = YES;
	}];

	expect(observedApp).toEventually(equal(app));
	expect(@(completed)).to(beFalsy());

	[app forceTerminate];
	expect(@(app.terminated)).toEventually(beTruthy());
	expect(@(completed)).toEventually(beTruthy());
});

it(@"should wait until multiple instances terminate", ^{
	SKIP_IF_RUNNING_ON_TRAVIS

	NSRunningApplication *app1 = [self launchTestApplicationWithEnvironment:nil];
	NSRunningApplication *app2 = [self launchTestApplicationWithEnvironment:nil];

	__block BOOL completed = NO;
	[[listener waitForTermination] subscribeCompleted:^{
		completed = YES;
	}];

	expect(@(completed)).to(beFalsy());

	[app1 forceTerminate];
	expect(@(app1.terminated)).toEventually(beTruthy());
	expect(@(completed)).to(beFalsy());

	[app2 forceTerminate];
	expect(@(app2.terminated)).toEventually(beTruthy());
	expect(@(completed)).toEventually(beTruthy());
});

QuickSpecEnd
