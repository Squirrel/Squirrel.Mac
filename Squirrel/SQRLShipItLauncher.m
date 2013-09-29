//
//  SQRLShipItLauncher.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-12.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLShipItLauncher.h"
#import "EXTScope.h"
#import "SQRLArguments.h"
#import <ServiceManagement/ServiceManagement.h>
#import <launch.h>

NSString * const SQRLShipItLauncherErrorDomain = @"SQRLShipItLauncherErrorDomain";

const NSInteger SQRLShipItLauncherErrorCouldNotStartService = 1;

@implementation SQRLShipItLauncher

- (xpc_connection_t)launch:(NSError **)errorPtr {
	NSBundle *squirrelBundle = [NSBundle bundleForClass:self.class];
	NSAssert(squirrelBundle != nil, @"Could not open Squirrel.framework bundle");

	NSRunningApplication *currentApp = NSRunningApplication.currentApplication;
	NSString *currentAppIdentifier = currentApp.bundleIdentifier ?: currentApp.executableURL.lastPathComponent.stringByDeletingPathExtension;
	NSString *jobLabel = [currentAppIdentifier stringByAppendingString:@".ShipIt"];

	CFErrorRef cfError;
	if (SMJobRemove(kSMDomainUserLaunchd, (__bridge CFStringRef)jobLabel, NULL, true, &cfError)) {
		#if DEBUG
		NSLog(@"Could not remove previous ShipIt job: %@", cfError);
		#endif

		if (cfError != NULL) {
			CFRelease(cfError);
			cfError = NULL;
		}
	}

	NSMutableDictionary *jobDict = [NSMutableDictionary dictionary];
	jobDict[@(LAUNCH_JOBKEY_LABEL)] = jobLabel;
	jobDict[@(LAUNCH_JOBKEY_NICE)] = @(-1);
	jobDict[@(LAUNCH_JOBKEY_KEEPALIVE)] = @NO;
	jobDict[@(LAUNCH_JOBKEY_ENABLETRANSACTIONS)] = @NO;
	jobDict[@(LAUNCH_JOBKEY_MACHSERVICES)] = @{
		jobLabel: @YES
	};

	jobDict[@(LAUNCH_JOBKEY_PROGRAMARGUMENTS)] = @[
		[squirrelBundle URLForResource:@"ShipIt" withExtension:nil].path,

		// Pass in the service name as the only argument, so ShipIt knows how to
		// broadcast itself.
		jobLabel
	];

	NSError *error = nil;
	NSURL *appSupportURL = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
	
	NSURL *squirrelAppSupportURL = [appSupportURL URLByAppendingPathComponent:jobLabel];

	BOOL created = (squirrelAppSupportURL == nil ? NO : [NSFileManager.defaultManager createDirectoryAtURL:squirrelAppSupportURL withIntermediateDirectories:YES attributes:nil error:&error]);

	if (!created) {
		NSLog(@"Could not create Application Support folder: %@", error);
	} else {
		jobDict[@(LAUNCH_JOBKEY_STANDARDOUTPATH)] = [squirrelAppSupportURL URLByAppendingPathComponent:@"ShipIt_stdout.log"].path;
		jobDict[@(LAUNCH_JOBKEY_STANDARDERRORPATH)] = [squirrelAppSupportURL URLByAppendingPathComponent:@"ShipIt_stderr.log"].path;
	}

	#if DEBUG
	jobDict[@(LAUNCH_JOBKEY_DEBUG)] = @YES;

	NSLog(@"ShipIt job dictionary: %@", jobDict);
	#endif

	if (!SMJobSubmit(kSMDomainUserLaunchd, (__bridge CFDictionaryRef)jobDict, NULL, &cfError)) {
		if (errorPtr) *errorPtr = (__bridge id)cfError;
		if (cfError != NULL) CFRelease(cfError);
		return NULL;
	}

	xpc_connection_t connection = xpc_connection_create_mach_service(jobLabel.UTF8String, NULL, 0);
	if (connection == NULL) {
		if (errorPtr != NULL) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Error opening XPC connection to %@", nil), jobLabel],
			};

			*errorPtr = [NSError errorWithDomain:SQRLShipItLauncherErrorDomain code:SQRLShipItLauncherErrorCouldNotStartService userInfo:userInfo];
		}

		return NULL;
	}
	
	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
		if (xpc_get_type(event) != XPC_TYPE_ERROR) return;

		@onExit {
			xpc_release(connection);
		};

		if (event != XPC_ERROR_CONNECTION_INVALID) {
			char *errorStr = xpc_copy_description(event);
			@onExit {
				free(errorStr);
			};

			NSLog(@"Received XPC error: %s", errorStr);
		}
	});

	return connection;
}

@end
