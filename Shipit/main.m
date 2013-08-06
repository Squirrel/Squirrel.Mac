//
//  main.m
//  shipit
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "NSError+SQRLVerbosityExtensions.h"
#import "SQRLArguments.h"
#import "SQRLInstaller.h"
#import "SQRLTerminationListener.h"

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		NSDictionary *defaults = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;

		id (^getRequiredArgument)(NSString *, Class) = ^(NSString *key, Class expectedClass) {
			id object = defaults[key];
			if (object == nil) {
				NSLog(@"Required argument -%@ was not set", key);
				exit(EXIT_FAILURE);
			}

			if (![object isKindOfClass:expectedClass]) {
				NSLog(@"Value \"%@\" for argument -%@ is not of the expected type", object, key);
				exit(EXIT_FAILURE);
			}

			return object;
		};

		NSURL * (^getRequiredURLArgument)(NSString *) = ^(NSString *key) {
			NSString *URLString = getRequiredArgument(key, NSString.class);
			NSURL *URL = [NSURL URLWithString:URLString];
			if (URL == nil) {
				NSLog(@"Value \"%@\" for argument -%@ is not a valid URL", URLString, key);
				exit(EXIT_FAILURE);
			}

			return URL;
		};

		NSURL *targetBundleURL = getRequiredURLArgument(SQRLTargetBundleURLArgumentName);
		NSURL *updateBundleURL = getRequiredURLArgument(SQRLUpdateBundleURLArgumentName);
		NSURL *backupURL = getRequiredURLArgument(SQRLBackupURLArgumentName);
		NSNumber *pid = getRequiredArgument(SQRLProcessIdentifierArgumentName, NSNumber.class);
		NSString *bundleIdentifier = getRequiredArgument(SQRLBundleIdentifierArgumentName, NSString.class);
		NSNumber *shouldRelaunch = getRequiredArgument(SQRLShouldRelaunchArgumentName, NSNumber.class);
		
		SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithProcessID:pid.intValue bundleIdentifier:bundleIdentifier bundleURL:targetBundleURL terminationHandler:^{
			SQRLInstaller *installer = [[SQRLInstaller alloc] initWithTargetBundleURL:targetBundleURL updateBundleURL:updateBundleURL backupURL:backupURL];
			
			NSError *error = nil;
			if (![installer installUpdateWithError:&error]) {
				NSLog(@"Error installing update: %@", error.sqrl_verboseDescription);
				exit(EXIT_FAILURE);
			}
			
			if (shouldRelaunch.boolValue) {
				[NSWorkspace.sharedWorkspace launchApplicationAtURL:targetBundleURL options:NSWorkspaceLaunchDefault configuration:nil error:NULL];
			}
			
			exit(EXIT_SUCCESS);
		}];

		[listener beginListening];
		CFRunLoopRun();
	}
	
	NSLog(@"Terminating from run loop exit");
	return EXIT_SUCCESS;
}

