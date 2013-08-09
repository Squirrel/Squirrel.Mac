//
//  SQRLTerminationListener.m
//  Squirrel
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLTerminationListener.h"

@interface SQRLTerminationListener ()

@property (nonatomic, assign, readonly) pid_t processIdentifier;
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@property (nonatomic, strong, readonly) NSURL *bundleURL;
@property (nonatomic, copy, readonly) void (^terminationHandler)(void);

// Whether the target has terminated.
//
// This should only be used while synchronized on self.
@property (nonatomic, assign) BOOL terminated;

@end

@implementation SQRLTerminationListener

#pragma mark Lifecycle

- (id)initWithProcessID:(pid_t)processID bundleIdentifier:(NSString *)bundleIdentifier bundleURL:(NSURL *)bundleURL terminationHandler:(void (^)(void))terminationHandler {
	NSParameterAssert(bundleIdentifier != nil);
	NSParameterAssert(bundleURL != nil);
	NSParameterAssert(terminationHandler != nil);
	
	self = [super init];
	if (self == nil) return nil;
	
	_bundleIdentifier = [bundleIdentifier copy];
	_terminationHandler = [terminationHandler copy];
	_bundleURL = bundleURL;

	return self;
}

- (void)dealloc {
	[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

#pragma mark Termination Listening

- (void)beginListening {
	[NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(workspaceApplicationDidTerminate:) name:NSWorkspaceDidTerminateApplicationNotification object:nil];

	NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:self.bundleIdentifier];
	for (NSRunningApplication *application in apps) {
		if ([application.bundleURL isEqual:self.bundleURL]) {
			if (application.terminated) [self targetDidTerminate];
			return;
		}
	}

	// If we didn't find a matching URL in running applications, it's already
	// terminated.
	[self targetDidTerminate];
}

- (void)targetDidTerminate {
	@synchronized (self) {
		if (self.terminated) return;
		self.terminated = YES;

		self.terminationHandler();
		[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceDidTerminateApplicationNotification object:nil];
	}
}

#pragma mark NSWorkspace

- (void)workspaceApplicationDidTerminate:(NSNotification *)notification {
	NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
	
	if (![application.bundleIdentifier isEqualToString:self.bundleIdentifier] || ![application.bundleURL isEqual:self.bundleURL]) {
		// Ignore termination of other apps.
		return;
	}
	
	[self targetDidTerminate];
}

@end
