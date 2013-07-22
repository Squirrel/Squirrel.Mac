//
//  SQRLUpdaterSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

SpecBegin(SQRLUpdater)

it(@"should be a thing", ^{
	SQRLUpdater *updater = [[SQRLUpdater alloc] init];
	expect(updater).notTo.beNil();
});

SpecEnd
