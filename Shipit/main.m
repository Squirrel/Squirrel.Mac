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

typedef void (^SQRLReplyHandler)(BOOL success, NSString *errorString);

static NSString *NSStringFromXPCObject(xpc_object_t object) {
	char *desc = xpc_copy_description(object);
	NSString *str = @(desc);
	free(desc);

	return str;
}

static void install(xpc_object_t event, BOOL shouldWait, SQRLReplyHandler replyHandler) {
	NSURL * (^getRequiredURLArgument)(const char *) = ^ id (const char *key) {
		const char *URLString = xpc_dictionary_get_string(event, key);
		if (URLString == NULL) {
			replyHandler(NO, [NSString stringWithFormat:@"Required key \"%s\" not provided", key]);
			return nil;
		}

		NSURL *URL = [NSURL URLWithString:@(URLString)];
		if (URL == nil) {
			replyHandler(NO, [NSString stringWithFormat:@"Value \"%s\" for key \"%s\" is not a valid URL", URLString, key]);
		}

		return URL;
	};

	NSURL *targetBundleURL = getRequiredURLArgument(SQRLTargetBundleURLKey);
	NSURL *updateBundleURL = getRequiredURLArgument(SQRLUpdateBundleURLKey);
	NSURL *backupURL = getRequiredURLArgument(SQRLBackupURLKey);
	if (targetBundleURL == nil || updateBundleURL == nil || backupURL == nil) return;

	void (^installUpdate)(BOOL) = ^(BOOL shouldRelaunch) {
		SQRLInstaller *installer = [[SQRLInstaller alloc] initWithTargetBundleURL:targetBundleURL updateBundleURL:updateBundleURL backupURL:backupURL];
		
		NSError *error = nil;
		if (![installer installUpdateWithError:&error]) {
			replyHandler(NO, [NSString stringWithFormat:@"Error installing update: %@", error.sqrl_verboseDescription]);
			return;
		}
		
		if (shouldRelaunch && ![NSWorkspace.sharedWorkspace launchApplicationAtURL:targetBundleURL options:NSWorkspaceLaunchDefault configuration:nil error:&error]) {
			replyHandler(NO, [NSString stringWithFormat:@"Error relaunching target application at %@: %@", targetBundleURL, error.sqrl_verboseDescription]);
			return;
		}
		
		replyHandler(YES, nil);
	};

	if (!shouldWait) {
		installUpdate(NO);
		return;
	}

	const char *bundleIdentifier = xpc_dictionary_get_string(event, SQRLBundleIdentifierKey);
	if (bundleIdentifier == NULL) {
		replyHandler(NO, [NSString stringWithFormat:@"Required key \"%s\" not provided", SQRLBundleIdentifierKey]);
		return;
	}

	pid_t pid = (pid_t)xpc_dictionary_get_int64(event, SQRLProcessIdentifierKey);
	BOOL shouldRelaunch = xpc_dictionary_get_bool(event, SQRLShouldRelaunchKey);
	
	SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithProcessID:pid bundleIdentifier:@(bundleIdentifier) bundleURL:targetBundleURL terminationHandler:^{
		NSLog(@"Target process terminated, installing update");
		installUpdate(shouldRelaunch);
	}];

	[listener beginListening];
}

static void listenForTermination(xpc_object_t event, SQRLReplyHandler replyHandler) {
	pid_t pid = (pid_t)xpc_dictionary_get_int64(event, SQRLProcessIdentifierKey);
	const char *bundleIdentifier = xpc_dictionary_get_string(event, SQRLBundleIdentifierKey);
	const char *bundleURLString = xpc_dictionary_get_string(event, SQRLTargetBundleURLKey);

	SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithProcessID:pid bundleIdentifier:@(bundleIdentifier) bundleURL:[NSURL URLWithString:@(bundleURLString)] terminationHandler:^{
		replyHandler(YES, nil);
	}];
	
	[listener beginListening];
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

		SQRLReplyHandler replyHandler = ^(BOOL success, NSString *errorString) {};

		xpc_object_t reply = xpc_dictionary_create_reply(event);
		if (reply != NULL) {
			replyHandler = [^(BOOL success, NSString *errorString) {
				xpc_dictionary_set_bool(reply, SQRLShipItSuccessKey, success);
				if (errorString != nil) xpc_dictionary_set_string(reply, SQRLShipItErrorKey, errorString.UTF8String);

				xpc_connection_send_message(xpc_dictionary_get_remote_connection(reply), reply);
				xpc_release(reply);
			} copy];
		}

		const char *command = xpc_dictionary_get_string(event, SQRLShipItCommandKey);
		if (strcmp(command, SQRLShipItInstallCommand) == 0) {
			install(event, YES, replyHandler);
		} else if (strcmp(command, SQRLShipItListenForTerminationCommand) == 0) {
			listenForTermination(event, replyHandler);
		} else if (strcmp(command, SQRLShipItInstallWithoutWaitingCommand) == 0) {
			install(event, NO, replyHandler);
		}
	});
	
	xpc_connection_resume(client);
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		#if DEBUG
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

