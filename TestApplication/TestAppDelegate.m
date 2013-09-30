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

	@weakify(self);

	RACSignal *updates = [[[[[[RACObserve(self.updater, state)
		filter:^ BOOL (NSNumber *state) {
			return state.unsignedIntegerValue == SQRLUpdaterStateAwaitingRelaunch;
		}]
		flattenMap:^(id _) {
			@strongify(self);
			return [self.updater prepareUpdateForInstallation];
		}]
		doNext:^(SQRLDownloadedUpdate *update) {
			NSLog(@"Update ready to install: %@", update);
		}]
		catch:^(NSError *error) {
			NSLog(@"Error in updater: %@", error);
			return [RACSignal return:nil];
		}]
		setNameWithFormat:@"updates"]
		logAll];
	
	RACSignal *idling = [[[[RACObserve(self.updater, state)
		skip:1]
		filter:^ BOOL (NSNumber *state) {
			return state.unsignedIntegerValue == SQRLUpdaterStateIdle;
		}]
		setNameWithFormat:@"idling"]
		logAll];

	RACSignal *termination = [[RACSignal
		merge:@[ updates, idling ]]
		mapReplace:self];
	
	[NSApp rac_liftSelector:@selector(terminate:) withSignals:termination, nil];

	[self.updater checkForUpdates];
}

@end
