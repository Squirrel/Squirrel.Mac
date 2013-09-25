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
#import <Security/Security.h>

NSString * const SQRLShipItLauncherErrorDomain = @"SQRLShipItLauncherErrorDomain";

const NSInteger SQRLShipItLauncherErrorCouldNotStartService = 1;

@implementation SQRLShipItLauncher

+ (xpc_connection_t)launchPrivileged:(BOOL)privileged error:(NSError **)errorPtr {
	NSBundle *squirrelBundle = [NSBundle bundleForClass:self.class];
	NSAssert(squirrelBundle != nil, @"Could not open Squirrel.framework bundle");

	NSRunningApplication *currentApp = NSRunningApplication.currentApplication;
	NSString *currentAppIdentifier = currentApp.bundleIdentifier ?: currentApp.executableURL.lastPathComponent.stringByDeletingPathExtension;
	NSString *jobLabel = [currentAppIdentifier stringByAppendingString:@".ShipIt"];

	CFStringRef domain = (privileged ? kSMDomainSystemLaunchd : kSMDomainUserLaunchd);

	AuthorizationRef authorization = NULL;
	if (privileged) {
		AuthorizationItem rightItems[] = {
			{
				.name = kSMRightModifySystemDaemons,
			},
		};
		AuthorizationRights rights = {
			.count = sizeof(rightItems) / sizeof(*rightItems),
			.items = rightItems,
		};

		NSString *prompt = [NSString stringWithFormat:NSLocalizedString(@"%@ is installing an updated version.", @"SQRLShipItLauncher, launch shipit, authorization prompt"), currentApp.localizedName];

		NSString *iconName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleIconFile"];
		NSString *iconPath = (iconName == nil ? nil : [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:iconName].path);

		AuthorizationItem environmentItems[] = {
			{
				.name = kAuthorizationEnvironmentPrompt,
				.valueLength = strlen(prompt.UTF8String),
				.value = (void *)prompt.UTF8String,
			},
			{
				.name = kAuthorizationEnvironmentIcon,
				.valueLength = iconPath == nil ? 0 : strlen(iconPath.UTF8String),
				.value = (void *)iconPath.UTF8String,
			},
		};
		AuthorizationEnvironment environment = {
			.count = sizeof(environmentItems) / sizeof(*environmentItems),
			.items = environmentItems,
		};

		OSStatus authorizationError = AuthorizationCreate(&rights, &environment, kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights, &authorization);
		if (authorizationError != noErr) {
			if (errorPtr != NULL) {
				*errorPtr = [NSError errorWithDomain:NSOSStatusErrorDomain code:authorizationError userInfo:nil];
			}
			return NULL;
		}
	}
	@onExit {
		if (authorization != NULL) AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
	};

	CFErrorRef cfError;
	if (!SMJobRemove(domain, (__bridge CFStringRef)jobLabel, authorization, true, &cfError)) {
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
	if (appSupportURL == nil) {
		NSLog(@"Could not find Application Support folder: %@", error);
	} else {
		jobDict[@(LAUNCH_JOBKEY_STANDARDOUTPATH)] = [appSupportURL URLByAppendingPathComponent:@"ShipIt_stdout.log"].path;
		jobDict[@(LAUNCH_JOBKEY_STANDARDERRORPATH)] = [appSupportURL URLByAppendingPathComponent:@"ShipIt_stderr.log"].path;
	}

	#if DEBUG
	jobDict[@(LAUNCH_JOBKEY_DEBUG)] = @YES;

	NSLog(@"ShipIt job dictionary: %@", jobDict);
	#endif

	if (!SMJobSubmit(domain, (__bridge CFDictionaryRef)jobDict, authorization, &cfError)) {
		if (errorPtr != NULL) {
			*errorPtr = CFBridgingRelease(cfError);
		} else {
			CFRelease(cfError);
		}
		return NULL;
	}

	xpc_connection_t connection = xpc_connection_create_mach_service(jobLabel.UTF8String, NULL, privileged ? XPC_CONNECTION_MACH_SERVICE_PRIVILEGED : 0);
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
