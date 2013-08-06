//
//  main.m
//  shipit
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SQRLTerminationListener.h"
#import "SQRLInstaller.h"

// blerg
static SQRLTerminationListener *listener = nil;

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		NSArray *arguments = NSProcessInfo.processInfo.arguments;
		
		NSLog(@"arguments are %@", arguments);
		
		if (arguments.count < 7) {
			return EXIT_FAILURE;
		}
		
		NSURL *targetBundleURL = [NSURL URLWithString:arguments[1]];
		pid_t processIdentifier = atoi([arguments[2] UTF8String]);
		NSString *bundleIdentifier = [arguments[3] copy];
		NSURL *updateBundleURL = [NSURL URLWithString:arguments[4]];
		NSURL *backupURL = [NSURL URLWithString:arguments[5]];
		BOOL shouldRelaunch = [arguments[6] isEqualToString:@"1"];
		
		listener = [[SQRLTerminationListener alloc] initWithProcessID:processIdentifier bundleIdentifier:bundleIdentifier bundleURL:targetBundleURL terminationHandler:^{
			SQRLInstaller *installer = [[SQRLInstaller alloc] initWithTargetBundleURL:targetBundleURL updateBundleURL:updateBundleURL backupURL:backupURL];
			
			NSError *error = nil;
			if (![installer installUpdateWithError:&error]) {
				NSLog(@"Error installing update %@, %@", error, error.userInfo[NSUnderlyingErrorKey]);
				exit(EXIT_FAILURE);
			}
			
			if (shouldRelaunch) {
				[NSWorkspace.sharedWorkspace launchApplicationAtURL:targetBundleURL options:NSWorkspaceLaunchDefault configuration:nil error:NULL];
			}
			
			exit(EXIT_SUCCESS);
		}];
			
		CFRunLoopRun();
	}
	
	return EXIT_FAILURE;
}

