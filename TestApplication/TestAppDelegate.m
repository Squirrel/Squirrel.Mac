//
//  TestAppDelegate.m
//  TestApplication
//
//  Created by Justin Spahr-Summers on 2013-08-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "TestAppDelegate.h"

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
	[self.updater addObserver:self forKeyPath:@"state" options:0 context:NULL];
	[self.updater checkForUpdates];
}

- (void)dealloc {
	[self.updater removeObserver:self forKeyPath:@"state"];
}

#pragma mark KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(SQRLUpdater *)updater change:(NSDictionary *)change context:(void *)context {
	NSParameterAssert([updater isKindOfClass:SQRLUpdater.class]);

	if (updater.state == SQRLUpdaterStateAwaitingRelaunch) {
		[updater installUpdateIfNeeded:^(BOOL success, NSError *error) {
			if (success) {
				NSLog(@"Update installed");
			} else {
				NSLog(@"Error in updater: %@", error);
			}

			[NSApp terminate:self];
		}];
	} else if (updater.state == SQRLUpdaterStateIdle) {
		NSLog(@"Updater reset to idle state, terminating");
		[NSApp terminate:self];
	}
}

@end
