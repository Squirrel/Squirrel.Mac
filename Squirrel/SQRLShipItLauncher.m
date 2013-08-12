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

NSString * const SQRLShipItLauncherErrorDomain = @"SQRLShipItLauncherErrorDomain";

const NSInteger SQRLShipItLauncherErrorCouldNotStartService = 1;

@implementation SQRLShipItLauncher

- (xpc_connection_t)launch:(NSError **)error {
	xpc_connection_t connection = xpc_connection_create(SQRLShipItServiceLabel, NULL);
	if (connection == NULL) {
		if (error != NULL) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Error opening XPC connection to %s", nil), SQRLShipItServiceLabel],
			};

			*error = [NSError errorWithDomain:SQRLShipItLauncherErrorDomain code:SQRLShipItLauncherErrorCouldNotStartService userInfo:userInfo];
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
