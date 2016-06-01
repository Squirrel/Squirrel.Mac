//
//  SQRLDirectoryManagerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Squirrel/Squirrel.h>

#import "SQRLDirectoryManager.h"

QuickSpecBegin(SQRLDirectoryManagerSpec)

__block NSString *otestIdentifier;

beforeEach(^{
	otestIdentifier = NSProcessInfo.processInfo.environment[@"FORCE_APP_IDENTIFIER"];
	expect(otestIdentifier).notTo(beNil());
});

it(@"should initialize", ^{
	SQRLDirectoryManager *manager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:otestIdentifier];
	expect(manager).notTo(beNil());
});

it(@"should create a manager for the current app", ^{
	SQRLDirectoryManager *manager = SQRLDirectoryManager.currentApplicationManager;
	expect(manager).notTo(beNil());
	expect(manager).to(equal([[SQRLDirectoryManager alloc] initWithApplicationIdentifier:otestIdentifier]));
});

it(@"should send an Application Support URL", ^{
	SQRLDirectoryManager *manager = SQRLDirectoryManager.currentApplicationManager;

	NSError *error = nil;
	NSURL *appSupportURL = [[manager storageURL] firstOrDefault:nil success:NULL error:&error];
	expect(appSupportURL).notTo(beNil());
	expect(error).to(beNil());

	__block BOOL directory = NO;
	expect(@([NSFileManager.defaultManager fileExistsAtPath:appSupportURL.path isDirectory:&directory])).to(beTruthy());
	expect(@(directory)).to(beTruthy());
});

it(@"should send a ShipIt state URL", ^{
	SQRLDirectoryManager *manager = SQRLDirectoryManager.currentApplicationManager;

	NSError *error = nil;
	NSURL *stateURL = [[manager shipItStateURL] firstOrDefault:nil success:NULL error:&error];
	expect(stateURL).notTo(beNil());
	expect(error).to(beNil());
});

QuickSpecEnd
