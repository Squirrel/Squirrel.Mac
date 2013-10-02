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
	
	NSLog(@"Redirecting logging to %@", logPath);
	freopen(logPath.fileSystemRepresentation, "a+", stderr);

	atexit_b(^{
		NSLog(@"TestApplication quitting");
	});

	NSString *updateURLString = NSProcessInfo.processInfo.environment[@"SQRLUpdateFromURL"];
	if (updateURLString == nil) {
		NSLog(@"Skipping update installation");
		return;
	}

	NSLog(@"Installing update from URL %@", updateURLString);

	NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:updateURLString]];
	self.updater = [[SQRLUpdater alloc] initWithUpdateRequest:request];

	[[[[[[[[RACSignal
		defer:^{
			return [self.updater.checkForUpdatesCommand execute:RACUnit.defaultUnit];
		}]
		doNext:^(SQRLDownloadedUpdate *update) {
			NSLog(@"Got a candidate update: %@", update);
		}]
		// Retry until we get the expected release.
		delay:0.1]
		repeat]
		skipUntilBlock:^(SQRLDownloadedUpdate *update) {
			return [update.releaseName isEqual:@"Final"];
		}]
		doNext:^(SQRLDownloadedUpdate *update) {
			NSLog(@"Update ready to install: %@", update);
		}]
		catch:^(NSError *error) {
			NSLog(@"Error in updater: %@", error);
			return [RACSignal empty];
		}]
		subscribeCompleted:^{
			[NSApp terminate:self];
		}];
}

@end
