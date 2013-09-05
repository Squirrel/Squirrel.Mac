//
//  SQRLDeepCodesignSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 2013-09-05.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

SpecBegin(SQRLDeepCodesign)

it(@"should deep codesign the test application", ^{
	NSURL *testApplicationLocation = self.testApplicationURL;
	
	NSBundle *testsBundle = [NSBundle bundleWithIdentifier:@"com.github.SquirrelTests"];
	NSURL *deepCodesignLocation = [testsBundle URLForResource:@"deep-codesign" withExtension:nil];
	expect([deepCodesignLocation resourceValuesForKeys:@[NSURLIsExecutableKey] error:NULL][NSURLIsExecutableKey]).to.equal(@(1));
	
	NSTask *deepCodesignTask = [[NSTask alloc] init];
	deepCodesignTask.launchPath = deepCodesignLocation.path;
	deepCodesignTask.environment = @{
		@"CODE_SIGN_IDENTITY": @"-",
		@"CONFIGURATION_BUILD_DIR": testApplicationLocation.URLByDeletingLastPathComponent.path,
		@"FULL_PRODUCT_NAME": testApplicationLocation.lastPathComponent,
	};
	
	[deepCodesignTask launch];
	[deepCodesignTask waitUntilExit];
	
	expect(@([deepCodesignTask terminationStatus])).to.equal(@(0));
});

SpecEnd
