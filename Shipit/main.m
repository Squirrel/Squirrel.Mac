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
#import "SQRLInstaller.h"

typedef BOOL (^SQRLInstallationHandler)(NSString **errorString);

static NSString *NSStringFromXPCObject(xpc_object_t object) {
	char *desc = xpc_copy_description(object);
	NSString *str = @(desc);
	free(desc);

	return str;
}

static SQRLInstallationHandler prepareInstallation(xpc_object_t event) {
	NSURL *targetBundleURL = [NSURL URLWithString:@(xpc_dictionary_get_string(event, SQRLTargetBundleURLKey))];
	NSURL *updateBundleURL = [NSURL URLWithString:@(xpc_dictionary_get_string(event, SQRLUpdateBundleURLKey))];
	NSURL *backupURL = [NSURL URLWithString:@(xpc_dictionary_get_string(event, SQRLBackupURLKey))];
	if (targetBundleURL == nil || updateBundleURL == nil || backupURL == nil) return nil;

	BOOL shouldRelaunch = xpc_dictionary_get_bool(event, SQRLShouldRelaunchKey);
	return ^(NSString **errorString) {
		NSLog(@"Beginning installation…");

		SQRLInstaller *installer = [[SQRLInstaller alloc] initWithTargetBundleURL:targetBundleURL updateBundleURL:updateBundleURL backupURL:backupURL];

		NSError *error = nil;
		if (![installer installUpdateWithError:&error]) {
			NSString *message = [NSString stringWithFormat:@"Error installing update: %@", error.sqrl_verboseDescription];
			NSLog(@"%@", message);

			if (errorString != NULL) *errorString = message;
			return NO;
		}
		
		NSLog(@"Installation completed successfully");
		
		if (shouldRelaunch && ![NSWorkspace.sharedWorkspace launchApplicationAtURL:targetBundleURL options:NSWorkspaceLaunchDefault configuration:nil error:&error]) {
			NSString *message = [NSString stringWithFormat:@"Error relaunching target application at %@: %@", targetBundleURL, error.sqrl_verboseDescription];
			NSLog(@"%@", message);

			if (errorString != NULL) *errorString = message;
			return NO;
		}
		
		return YES;
	};
}

static void handleConnection(xpc_connection_t client) {
	NSLog(@"Got client connection: %s", xpc_copy_description(client));

	xpc_connection_set_event_handler(client, ^(xpc_object_t event) {
		NSLog(@"Got event on client connection: %s", xpc_copy_description(event));

		xpc_type_t type = xpc_get_type(event);
		if (type == XPC_TYPE_ERROR) {
			if (event != XPC_ERROR_CONNECTION_INVALID) {
				NSLog(@"XPC error: %@", NSStringFromXPCObject(event));
			}

			return;
		}

		xpc_object_t reply = xpc_dictionary_create_reply(event);
		@onExit {
			xpc_release(reply);
		};

		const char *command = xpc_dictionary_get_string(event, SQRLShipItCommandKey);
		if (strcmp(command, SQRLShipItInstallCommand) == 0) {
			SQRLInstallationHandler handler = prepareInstallation(event);
			if (handler == nil) {
				xpc_dictionary_set_bool(reply, SQRLShipItSuccessKey, false);
				xpc_dictionary_set_string(reply, SQRLShipItErrorKey, "Required key not provided");
				xpc_connection_send_message(xpc_dictionary_get_remote_connection(reply), reply);
				return;
			}
			
			NSString *errorString = nil;
			BOOL success = handler(&errorString);
				
			xpc_dictionary_set_bool(reply, SQRLShipItSuccessKey, success);
			if (errorString != nil) xpc_dictionary_set_string(reply, SQRLShipItErrorKey, errorString.UTF8String);
			xpc_connection_send_message(xpc_dictionary_get_remote_connection(reply), reply);
		}
	});
	
	xpc_connection_resume(client);
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		atexit_b(^{
			NSLog(@"ShipIt quitting");
		});

		NSLog(@"ShipIt started");

		xpc_connection_t service = xpc_connection_create_mach_service(SQRLShipItServiceLabel, NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
		if (service == NULL) {
			NSLog(@"Could not start Mach service \"%s\"", SQRLShipItServiceLabel);
			exit(EXIT_FAILURE);
		}

		@onExit {
			xpc_release(service);
		};
		
		xpc_connection_set_event_handler(service, ^(xpc_object_t connection) {
			handleConnection(connection);
		});
		
		xpc_connection_resume(service);
		dispatch_main();
	}

	return EXIT_SUCCESS;
}

