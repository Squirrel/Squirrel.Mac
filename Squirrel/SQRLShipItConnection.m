//
//  SQRLShipItConnection.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-12.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLShipItConnection.h"
#import "EXTScope.h"
#import "SQRLDirectoryManager.h"
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>
#import <launch.h>
#import "SQRLAuthorization.h"
#import "SQRLShipItRequest.h"

NSString * const SQRLShipItConnectionErrorDomain = @"SQRLShipItConnectionErrorDomain";

const NSInteger SQRLShipItConnectionErrorCouldNotStartService = 1;

@interface SQRLShipItConnection ()
@property (readonly, nonatomic, assign) BOOL privileged;
@end

@implementation SQRLShipItConnection

+ (NSString *)shipItInstallerJobLabel {
	NSString *currentAppIdentifier = NSBundle.mainBundle.bundleIdentifier ?: [NSString stringWithFormat:@"%@:%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier];
	return [currentAppIdentifier stringByAppendingString:@".ShipIt"];
}

+ (NSMutableDictionary *)jobDictionaryWithLabel:(NSString *)jobLabel executableName:(NSString *)executableName arguments:(NSArray *)arguments {
	NSParameterAssert(jobLabel != nil);
	NSParameterAssert(executableName != nil);
	NSParameterAssert(arguments != nil);

	NSMutableDictionary *jobDict = [NSMutableDictionary dictionary];
	jobDict[@(LAUNCH_JOBKEY_LABEL)] = jobLabel;
	jobDict[@(LAUNCH_JOBKEY_NICE)] = @(-1);
	jobDict[@(LAUNCH_JOBKEY_ENABLETRANSACTIONS)] = @NO;
	jobDict[@(LAUNCH_JOBKEY_THROTTLEINTERVAL)] = @2;

	NSBundle *squirrelBundle = [NSBundle bundleForClass:self.class];
	NSAssert(squirrelBundle != nil, @"Could not open Squirrel.framework bundle");

	NSMutableArray *fullArguments = [NSMutableArray arrayWithObject:[squirrelBundle pathForResource:executableName ofType:nil]];
	[fullArguments addObjectsFromArray:arguments];
	jobDict[@(LAUNCH_JOBKEY_PROGRAMARGUMENTS)] = fullArguments;

	return jobDict;
}

+ (RACSignal *)shipItInstallerJobDictionary {
	NSString *jobLabel = self.shipItInstallerJobLabel;

	return [[[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:jobLabel];
			return [directoryManager applicationSupportURL];
		}]
		map:^(NSURL *appSupportURL) {
			NSMutableArray *arguments = [[NSMutableArray alloc] init];

			// Pass in the service name so ShipIt knows how to broadcast itself.
			[arguments addObject:jobLabel];

			NSMutableDictionary *jobDict = [self jobDictionaryWithLabel:jobLabel executableName:@"shipit-installer" arguments:arguments];
			jobDict[@(LAUNCH_JOBKEY_KEEPALIVE)] = @{
				@(LAUNCH_JOBKEY_KEEPALIVE_SUCCESSFULEXIT): @NO
			};

			jobDict[@(LAUNCH_JOBKEY_STANDARDOUTPATH)] = [appSupportURL URLByAppendingPathComponent:@"ShipIt_stdout.log"].path;
			jobDict[@(LAUNCH_JOBKEY_STANDARDERRORPATH)] = [appSupportURL URLByAppendingPathComponent:@"ShipIt_stderr.log"].path;
			
			return jobDict;
		}]
		setNameWithFormat:@"+shipItInstallerJobDictionary"];
}

+ (RACSignal *)shipItAuthorization {
	return [[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			AuthorizationItem rightItems[] = {
				{
					.name = kSMRightModifySystemDaemons,
				},
			};

			AuthorizationRights rights = {
				.count = sizeof(rightItems) / sizeof(*rightItems),
				.items = rightItems,
			};

			NSString *prompt = NSLocalizedString(@"An update is ready to install.", @"SQRLShipItConnection, launch shipit, authorization prompt");

			NSString *iconName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleIconFile"];
			NSString *iconPath = (iconName == nil ? nil : [NSBundle.mainBundle pathForImageResource:iconName]);

			AuthorizationItem environmentItems[] = {
				{
					.name = kAuthorizationEnvironmentPrompt,
					.valueLength = strlen(prompt.UTF8String),
					.value = (void *)prompt.UTF8String,
				},
				{
					.name = kAuthorizationEnvironmentIcon,
					.valueLength = (iconPath == nil ? 0 : strlen(iconPath.UTF8String)),
					.value = (void *)iconPath.UTF8String,
				},
			};

			AuthorizationEnvironment environment = {
				.count = sizeof(environmentItems) / sizeof(*environmentItems),
				.items = environmentItems,
			};

			AuthorizationRef authorization = NULL;
			OSStatus authorizationError = AuthorizationCreate(&rights, &environment, kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights, &authorization);

			if (authorizationError == noErr) {
				[subscriber sendNext:[[SQRLAuthorization alloc] initWithAuthorization:authorization]];
				[subscriber sendCompleted];
			} else {
				[subscriber sendError:[NSError errorWithDomain:NSOSStatusErrorDomain code:authorizationError userInfo:nil]];
			}

			return nil;
		}]
		setNameWithFormat:@"+shipItAuthorization"];
}

- (instancetype)initWithRootPrivileges:(BOOL)rootPrivileges {
	self = [self init];
	if (self == nil) return nil;

	_privileged = rootPrivileges;

	return self;
}

- (RACSignal *)sendRequest:(SQRLShipItRequest *)request {
	NSParameterAssert(request != nil);

	return [[[self
		submitInstallerJobForRequestIfNeeded:request]
		concat:[RACSignal defer:^{

		}]]
		setNameWithFormat:@"%@ -sendRequest: %@", self, request];
}

- (RACSignal *)submitInstallerJobForRequestIfNeeded:(SQRLShipItRequest *)request {
	// TODO implement lazy submission when the job is already loaded in launchd

	CFStringRef domain = NULL; RACSignal *authorization;
	if (self.privileged) {
		domain = kSMDomainSystemLaunchd;
		authorization = self.class.shipItAuthorization;
	} else {
		domain = kSMDomainUserLaunchd;
		authorization = [RACSignal return:nil];
	}

	return [[[RACSignal
		zip:@[
			self.class.shipItInstallerJobDictionary,
			authorization,
		] reduce:^(NSDictionary *job, SQRLAuthorization *authorization) {
			return [self submitJob:job domain:(__bridge id)domain authorization:authorization];
		}]
		flatten]
		setNameWithFormat:@"%@ -submitInstallerJobForRequestIfNeeded: %@", self, request];
}

- (RACSignal *)submitJob:(NSDictionary *)job domain:(NSString *)domain authorization:(SQRLAuthorization *)authorizationValue {
	return [[RACSignal
		defer:^{
			NSString *jobLabel = job[@(LAUNCH_JOBKEY_LABEL)];

			AuthorizationRef authorization = authorizationValue.authorization;

			CFErrorRef cfError;
			if (!SMJobRemove((__bridge CFStringRef)domain, (__bridge CFStringRef)jobLabel, authorization, true, &cfError)) {
				NSError *error = CFBridgingRelease(cfError);
				cfError = NULL;

				if (![error.domain isEqual:(__bridge id)kSMErrorDomainLaunchd] || error.code != kSMErrorJobNotFound) {
					NSLog(@"Could not remove previous ShipIt job %@: %@", jobLabel, error);
				}
			}

			if (!SMJobSubmit((__bridge CFStringRef)domain, (__bridge CFDictionaryRef)job, authorization, &cfError)) {
				return [RACSignal error:CFBridgingRelease(cfError)];
			}
			
			return [RACSignal empty];
		}]
		setNameWithFormat:@"%@ -submitJob: %@ domain: %@ authorization: %@", self, job, domain, authorizationValue];
}

@end
