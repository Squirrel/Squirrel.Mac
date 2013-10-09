//
//  SQRLShipItLauncher.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-12.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLShipItLauncher.h"
#import "EXTScope.h"
#import "SQRLDirectoryManager.h"
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>
#import <launch.h>

NSString * const SQRLShipItLauncherErrorDomain = @"SQRLShipItLauncherErrorDomain";

const NSInteger SQRLShipItLauncherErrorCouldNotStartService = 1;

@implementation SQRLShipItLauncher

+ (NSString *)shipItJobLabel {
	NSRunningApplication *currentApp = NSRunningApplication.currentApplication;
	NSString *currentAppIdentifier = currentApp.bundleIdentifier ?: currentApp.executableURL.lastPathComponent.stringByDeletingPathExtension;
	return [currentAppIdentifier stringByAppendingString:@".ShipIt"];
}

+ (RACSignal *)launchPrivileged:(BOOL)privileged {
	SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:self.shipItJobLabel];

	return [[[directoryManager
		applicationSupportURL]
		flattenMap:^(NSURL *appSupportURL) {
			NSBundle *squirrelBundle = [NSBundle bundleForClass:self.class];
			NSAssert(squirrelBundle != nil, @"Could not open Squirrel.framework bundle");

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

				NSString *prompt = NSLocalizedString(@"An update is ready to install.", @"SQRLShipItLauncher, launch shipit, authorization prompt");

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
					return [RACSignal error:[NSError errorWithDomain:NSOSStatusErrorDomain code:authorizationError userInfo:nil]];
				}
			}

			@onExit {
				if (authorization != NULL) AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
			};

			NSString *jobLabel = self.shipItJobLabel;

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
			jobDict[@(LAUNCH_JOBKEY_ENABLETRANSACTIONS)] = @NO;
			jobDict[@(LAUNCH_JOBKEY_THROTTLEINTERVAL)] = @2;
			jobDict[@(LAUNCH_JOBKEY_KEEPALIVE)] = @{
				@(LAUNCH_JOBKEY_KEEPALIVE_SUCCESSFULEXIT): @NO
			};

			jobDict[@(LAUNCH_JOBKEY_MACHSERVICES)] = @{
				jobLabel: @YES
			};

			NSMutableArray *arguments = [[NSMutableArray alloc] init];
			[arguments addObject:[squirrelBundle URLForResource:@"ShipIt" withExtension:nil].path];

			// Pass in the service name so ShipIt knows how to broadcast itself.
			[arguments addObject:jobLabel];

			jobDict[@(LAUNCH_JOBKEY_PROGRAMARGUMENTS)] = arguments;
			jobDict[@(LAUNCH_JOBKEY_STANDARDOUTPATH)] = [appSupportURL URLByAppendingPathComponent:@"ShipIt_stdout.log"].path;
			jobDict[@(LAUNCH_JOBKEY_STANDARDERRORPATH)] = [appSupportURL URLByAppendingPathComponent:@"ShipIt_stderr.log"].path;

			#if DEBUG
			jobDict[@(LAUNCH_JOBKEY_DEBUG)] = @YES;
			#endif

			if (!SMJobSubmit(domain, (__bridge CFDictionaryRef)jobDict, authorization, &cfError)) {
				return [RACSignal error:CFBridgingRelease(cfError)];
			}

			return [RACSignal empty];
		}]
		setNameWithFormat:@"+launchPrivileged: %i", (int)privileged];
}

@end
