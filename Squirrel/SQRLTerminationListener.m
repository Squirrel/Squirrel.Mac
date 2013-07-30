//
//  SQRLTerminationListener.m
//  Squirrel
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLTerminationListener.h"

@interface SQRLTerminationListener ()

@property (nonatomic, assign) pid_t processIdentifier;
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, strong) NSURL *bundleURL;
@property (nonatomic, copy) void (^terminationHandler)(void);

@end

@implementation SQRLTerminationListener

- (id)initWithProcessID:(pid_t)processID bundleIdentifier:(NSString *)bundleIdentifier bundleURL:(NSURL *)bundleURL terminationHandler:(void (^)(void))terminationHandler {
    NSParameterAssert(bundleIdentifier != nil);
    NSParameterAssert(bundleURL != nil);
    NSParameterAssert(terminationHandler != nil);
    
    self = [super init];
    
    if (self == nil) return nil;
    
    _bundleIdentifier = [bundleIdentifier copy];
    _terminationHandler = [terminationHandler copy];
    _bundleURL = bundleURL;

    BOOL alreadyTerminated = (getppid() == 1); // ppid is launchd (1) => parent terminated already
	
	if (alreadyTerminated) [self parentDidTerminate];
    
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(workspaceApplicationDidTerminate:) name:NSWorkspaceDidTerminateApplicationNotification object:nil];

    return self;
}

- (void)parentDidTerminate {
    self.terminationHandler();
}

- (void)workspaceApplicationDidTerminate:(NSNotification *)notification {
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    
    if (![application.bundleIdentifier isEqualToString:self.bundleIdentifier] || ![application.bundleURL isEqual:self.bundleURL] || application.processIdentifier != self.processIdentifier) {
        
        
        return;
    }
    
    [self parentDidTerminate];
}

@end
