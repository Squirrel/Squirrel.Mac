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

typedef BOOL (^SQRLInstallationHandler)(NSString **errorString);

// The amount of time to wait after the XPC connection has closed before
// starting to update.
static const NSTimeInterval SQRLApplicationTerminationLeeway = 0.05;

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
		#if DEBUG
		NSLog(@"Beginning installation…");
		#endif

		SQRLInstaller *installer = [[SQRLInstaller alloc] initWithTargetBundleURL:targetBundleURL updateBundleURL:updateBundleURL backupURL:backupURL];

		NSError *error = nil;
		if (![installer installUpdateWithError:&error]) {
			NSString *message = [NSString stringWithFormat:@"Error installing update: %@", error.sqrl_verboseDescription];
			NSLog(@"%@", message);

			if (errorString != NULL) *errorString = message;
			return NO;
		}
		
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
	#if DEBUG
	NSLog(@"Got client connection: %s", xpc_copy_description(client));
	#endif

	xpc_connection_set_event_handler(client, ^(xpc_object_t event) {
		#if DEBUG
		NSLog(@"Got event on client connection: %s", xpc_copy_description(event));
		#endif

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

			xpc_dictionary_set_bool(reply, SQRLShipItSuccessKey, true);
			xpc_connection_send_message_with_reply(xpc_dictionary_get_remote_connection(reply), reply, dispatch_get_main_queue(), ^(xpc_object_t event) {
				xpc_transaction_begin();

				if (event != XPC_ERROR_CONNECTION_INVALID && event != XPC_ERROR_CONNECTION_INTERRUPTED) {
					NSLog(@"Unexpected client response to installation: %@", NSStringFromXPCObject(event));
				}

				dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SQRLApplicationTerminationLeeway * NSEC_PER_SEC));
				dispatch_after(time, dispatch_get_main_queue(), ^{
					handler(NULL);
					xpc_transaction_end();
				});
			});
		} else {
			#if DEBUG
			// This command is only used for unit testing.
			if (strcmp(command, SQRLShipItInstallWithoutWaitingCommand) == 0) {
				SQRLInstallationHandler handler = prepareInstallation(event);

				NSString *errorString = nil;
				BOOL success = handler(&errorString);

				xpc_dictionary_set_bool(reply, SQRLShipItSuccessKey, success);
				if (errorString != nil) xpc_dictionary_set_string(reply, SQRLShipItErrorKey, errorString.UTF8String);

				xpc_connection_send_message(xpc_dictionary_get_remote_connection(reply), reply);
			}
			#endif
		}
	});
	
	xpc_connection_resume(client);
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		#if DEBUG
		atexit_b(^{
			NSLog(@"ShipIt quitting");
		});

		NSString *folder = [NSBundle bundleWithIdentifier:@(SQRLShipItServiceLabel)].bundlePath.stringByDeletingLastPathComponent;
		NSString *logPath = [folder stringByAppendingPathComponent:@"ShipIt.log"];
		NSLog(@"Redirecting logging to %@", logPath);

		freopen(logPath.fileSystemRepresentation, "a+", stderr);

		NSLog(@"ShipIt started");
		#endif

		xpc_main(handleConnection);
	}

	return EXIT_SUCCESS;
}

