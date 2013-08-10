//
//  SQRLAppDelegate.m
//  TestApplication
//
//  Created by Justin Spahr-Summers on 2013-08-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLAppDelegate.h"

@implementation SQRLAppDelegate

#pragma mark Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	atexit_b(^{
		NSLog(@"TestApplication quitting");
	});

	NSString *updateURLString = NSProcessInfo.processInfo.environment[@"SQRLUpdateFromURL"];
	if (updateURLString == nil) {
		NSLog(@"Skipping update installation");
		return;
	}

	NSLog(@"Installing update from URL %@", updateURLString);

	SQRLUpdater.sharedUpdater.APIEndpoint = [NSURL URLWithString:updateURLString];
	[SQRLUpdater.sharedUpdater addObserver:self forKeyPath:@"state" options:0 context:NULL];
	[SQRLUpdater.sharedUpdater checkForUpdates];
}

- (void)dealloc {
	[SQRLUpdater.sharedUpdater removeObserver:self forKeyPath:@"state"];
}

#pragma mark KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(SQRLUpdater *)updater change:(NSDictionary *)change context:(void *)context {
	NSParameterAssert([updater isKindOfClass:SQRLUpdater.class]);

	if (updater.state == SQRLUpdaterStateAwaitingRelaunch) {
		[updater installUpdateIfNeeded:^(BOOL success) {
			if (success) {
				NSLog(@"Update ready for installation");
				[NSApp terminate:self];
			} else {
				NSLog(@"Error in updater, will not terminate");
			}
		}];
	}
}

@end
