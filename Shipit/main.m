//
//  main.m
//  shipit
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "EXTScope.h"
#import "NSError+SQRLVerbosityExtensions.h"
#import "SQRLArguments.h"
#import "SQRLArguments+Private.h"
#import "SQRLInstaller.h"
#import "SQRLTerminationListener.h"

#if TESTING
static void handleEvent(xpc_object_t event) {
	xpc_type_t type = xpc_get_type(event);
	xpc_connection_t remote = xpc_dictionary_get_remote_connection(event);

	if (type == XPC_TYPE_ERROR) {
		if (event == XPC_ERROR_CONNECTION_INVALID) {
			exit(EXIT_SUCCESS);
		} else {
			NSCAssert(NO, @"XPC error: %s", xpc_copy_description(event));
		}
	}

	NSString *command = @(xpc_dictionary_get_string(event, SQRLCommandKey));
	NSLog(@"Got command: %@", command);

	if ([command isEqual:@(SQRLCommandListenForTermination)]) {
		xpc_object_t reply = xpc_dictionary_create_reply(event);

		NSRunningApplication *parent = [NSRunningApplication runningApplicationWithProcessIdentifier:getppid()];
		NSCAssert(parent != nil, @"Could not find parent process");

		SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithProcessID:parent.processIdentifier bundleIdentifier:parent.bundleIdentifier bundleURL:parent.bundleURL terminationHandler:^{
			xpc_connection_send_message(remote, reply);
			xpc_release(reply);
		}];
		
		[listener beginListening];
	}
}

static void startEndpoint(xpc_endpoint_t endpoint) {
	xpc_connection_t connection = xpc_connection_create_from_endpoint(endpoint);
	NSCAssert(connection != NULL, @"NULL connection from endpoint %s", xpc_copy_description(endpoint));

	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
		handleEvent(event);
	});

	xpc_connection_resume(connection);
}

static void startXPC(void) {
	xpc_connection_t service = xpc_connection_create_mach_service(SQRLShipitServiceLabel, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
	NSCAssert(service != NULL, @"Failed to create %s service", SQRLShipitServiceLabel);

	@onExit {
		xpc_release(service);
	};
	
	xpc_connection_set_event_handler(service, ^(xpc_object_t connection) {
		xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
			xpc_type_t type = xpc_get_type(event);
			if (type == XPC_TYPE_ERROR) {
				if (event == XPC_ERROR_CONNECTION_INVALID) {
					exit(EXIT_SUCCESS);
				} else {
					NSCAssert(NO, @"XPC error: %s", xpc_copy_description(event));
				}
			}

			xpc_endpoint_t endpoint = xpc_dictionary_get_value(event, SQRLShipitEndpointKey);
			startEndpoint(endpoint);

			xpc_connection_cancel(connection);
		});

		xpc_connection_resume(connection);
	});
	
	xpc_connection_resume(service);
	CFRunLoopRun();
}
#endif

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		#if TESTING
		startXPC();
		return EXIT_SUCCESS;
		#endif

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
			
			if (shouldRelaunch.boolValue && ![NSWorkspace.sharedWorkspace launchApplicationAtURL:targetBundleURL options:NSWorkspaceLaunchDefault configuration:nil error:&error]) {
				NSLog(@"Error relaunching target application at %@: %@", targetBundleURL, error);
				exit(EXIT_FAILURE);
			}
			
			exit(EXIT_SUCCESS);
		}];

		[listener beginListening];
		CFRunLoopRun();
	}
	
	NSLog(@"Terminating from run loop exit");
	return EXIT_SUCCESS;
}

