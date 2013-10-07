//
//  SQRLTerminationListenerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-07.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLTerminationListener.h"

SpecBegin(SQRLTerminationListener)

__block SQRLTerminationListener *listener;

beforeEach(^{
	listener = [[SQRLTerminationListener alloc] initWithURL:self.testApplicationURL bundleIdentifier:self.testApplicationBundle.bundleIdentifier];
	expect(listener).notTo.beNil();
});

it(@"should complete immediately when the app is not running", ^{
	__block BOOL completed = NO;
	[[listener waitForTermination] subscribeCompleted:^{
		completed = YES;
	}];

	expect(completed).to.beTruthy();
});

it(@"should wait until one instance terminates", ^{
	NSRunningApplication *app = [self launchTestApplicationWithEnvironment:nil];

	__block NSRunningApplication *observedApp = nil;
	__block BOOL completed = NO;
	[[listener waitForTermination] subscribeNext:^(id x) {
		observedApp = x;
	} completed:^{
		completed = YES;
	}];

	expect(observedApp).will.equal(app);
	expect(completed).to.beFalsy();

	expect([app terminate]).to.beTruthy();
	expect(completed).will.beTruthy();
});

it(@"should wait until multiple instances terminate", ^{
	NSRunningApplication *app1 = [self launchTestApplicationWithEnvironment:nil];
	NSRunningApplication *app2 = [self launchTestApplicationWithEnvironment:nil];

	__block BOOL completed = NO;
	[[listener waitForTermination] subscribeCompleted:^{
		completed = YES;
	}];

	expect(completed).to.beFalsy();

	expect([app1 terminate]).to.beTruthy();
	expect(completed).to.beFalsy();

	expect([app2 terminate]).to.beTruthy();
	expect(completed).will.beTruthy();
});

SpecEnd
