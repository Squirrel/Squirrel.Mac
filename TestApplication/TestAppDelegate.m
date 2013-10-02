//
//  TestAppDelegate.m
//  TestApplication
//
//  Created by Justin Spahr-Summers on 2013-08-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "TestAppDelegate.h"
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>

@interface TestAppDelegate ()

@property (nonatomic, strong) SQRLUpdater *updater;

@end

@implementation TestAppDelegate

#pragma mark Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	NSString *folder = [NSBundle bundleWithIdentifier:@"com.github.Squirrel.TestApplication"].bundlePath.stringByDeletingLastPathComponent;
	NSString *logPath = [folder stringByAppendingPathComponent:@"TestApplication.log"];
	freopen(logPath.fileSystemRepresentation, "a+", stderr);

	atexit_b(^{
		NSLog(@"TestApplication quitting");
	});

	NSString *updateURLString = NSProcessInfo.processInfo.environment[@"SQRLUpdateFromURL"];
	if (updateURLString == nil) {
		NSLog(@"Skipping update installation");
		return;
	}

	NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:updateURLString]];
	self.updater = [[SQRLUpdater alloc] initWithUpdateRequest:request];

	__block NSUInteger updateCheckCount = 1;

	[[[[[[[[[RACSignal
		defer:^{
			NSLog(@"***** UPDATE CHECK %lu *****", (unsigned long)updateCheckCount);
			updateCheckCount++;

			return [self.updater.checkForUpdatesCommand execute:RACUnit.defaultUnit];
		}]
		doNext:^(SQRLDownloadedUpdate *update) {
			NSLog(@"Got a candidate update: %@", update);
		}]
		// Retry until we get the expected release.
		repeat]
		skipUntilBlock:^(SQRLDownloadedUpdate *update) {
			return [update.releaseName isEqual:@"Final"];
		}]
		take:1]
		doNext:^(id _) {
			NSLog(@"***** READY TO INSTALL UPDATE *****");
		}]
		timeout:10 onScheduler:RACScheduler.mainThreadScheduler]
		catch:^(NSError *error) {
			NSLog(@"Error in updater: %@", error);
			return [RACSignal empty];
		}]
		subscribeCompleted:^{
			[NSApp terminate:self];
		}];
}

@end
