//
//  NSProcessInfoExtensionsSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-09-16.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Squirrel/Squirrel.h>

QuickSpecBegin(NSProcessInfoExtensions)

describe(@"-sqrl_operatingSystemShortVersionString", ^{
	__block NSString *versionString;

	beforeEach(^{
		versionString = NSProcessInfo.processInfo.sqrl_operatingSystemShortVersionString;
		expect(versionString).notTo(beNil());
	});

	it(@"should follow major.minor.patch format", ^{
		NSError *error = nil;
		NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(\\.[0-9]+)*$" options:0 error:&error];
		expect(regex).notTo(beNil());
		expect(error).to(beNil());

		NSRange fullRange = NSMakeRange(0, versionString.length);
		NSRange matchRange = [regex rangeOfFirstMatchInString:versionString options:0 range:fullRange];
		expect(@(NSEqualRanges(matchRange, fullRange))).to(beTruthy());
	});

	it(@"should be numerically comparable", ^{
		expect(@([@"10.6.9" compare:versionString options:NSNumericSearch])).to(equal(@(NSOrderedAscending)));
	});
});

QuickSpecEnd
