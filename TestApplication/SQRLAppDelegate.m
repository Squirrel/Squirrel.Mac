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
	NSString *updateURLString = NSProcessInfo.processInfo.environment[@"SQRLUpdateFromURL"];
	if (updateURLString == nil) return;

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
		[updater installUpdateIfNeeded];
		[NSApp terminate:self];
	}
}

@end
