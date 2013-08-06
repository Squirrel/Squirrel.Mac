//
//  SQRLUpdaterSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

SpecBegin(SQRLUpdater)

it(@"should be a thing", ^{
	SQRLUpdater *updater = SQRLUpdater.sharedUpdater;
	expect(updater).notTo.beNil();
});

pending(@"should download an update when it doesn't match the current version");

pending(@"should unzip an update");

pending(@"should verify the code signature of an update");

pending(@"should install the update on relaunch");

pending(@"should fail to install a corrupt update");

SpecEnd
