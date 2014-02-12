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

+ (NSString *)shipItJobLabel {
	NSString *currentAppIdentifier = NSBundle.mainBundle.bundleIdentifier ?: [NSString stringWithFormat:@"%@:%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier];
	return [currentAppIdentifier stringByAppendingString:@".ShipIt"];
}

+ (NSMutableDictionary *)jobDictionaryWithLabel:(NSString *)jobLabel command:(NSString *)command arguments:(NSArray *)arguments {
	NSParameterAssert(jobLabel != nil);
	NSParameterAssert(command != nil);
	NSParameterAssert(arguments != nil);

	NSMutableDictionary *jobDict = [NSMutableDictionary dictionary];
	jobDict[@(LAUNCH_JOBKEY_LABEL)] = jobLabel;
	jobDict[@(LAUNCH_JOBKEY_NICE)] = @(-1);
	jobDict[@(LAUNCH_JOBKEY_ENABLETRANSACTIONS)] = @NO;
	jobDict[@(LAUNCH_JOBKEY_THROTTLEINTERVAL)] = @2;

	NSBundle *squirrelBundle = [NSBundle bundleForClass:self.class];
	NSAssert(squirrelBundle != nil, @"Could not open Squirrel.framework bundle");

	NSMutableArray *fullArguments = [NSMutableArray arrayWithObject:[squirrelBundle URLForResource:command withExtension:nil].path];
	[fullArguments addObjectsFromArray:arguments];
	jobDict[@(LAUNCH_JOBKEY_PROGRAMARGUMENTS)] = fullArguments;

	return jobDict;
}

+ (NSDictionary *)shipItWatcherJobDictionaryWithRequestURL:(NSURL *)requestURL readyURL:(NSURL *)readyURL {
	NSParameterAssert(requestURL != nil);
	NSParameterAssert(readyURL != nil);

	NSString *jobLabel = [self.shipItJobLabel stringByAppendingString:@".watcher"];

	NSMutableArray *arguments = [[NSMutableArray alloc] init];
	[arguments addObject:requestURL.path];
	[arguments addObject:readyURL.path];

	NSMutableDictionary *jobDict = [self jobDictionaryWithLabel:jobLabel command:@"shipit-watcher" arguments:arguments];
	jobDict[@(LAUNCH_JOBKEY_RUNATLOAD)] = @YES;

	return jobDict;
}

+ (RACSignal *)shipItInstallerJobDictionaryWithRequestURL:(NSURL *)requestURL readyURL:(NSURL *)readyURL {
	NSParameterAssert(requestURL != nil);
	NSParameterAssert(readyURL != nil);

	NSString *jobLabel = self.shipItJobLabel;

	return [[[RACSignal
		defer:^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:jobLabel];
			return [directoryManager applicationSupportURL];
		}]
		map:^(NSURL *appSupportURL) {
			NSMutableArray *arguments = [[NSMutableArray alloc] init];

			// Pass in the service name so ShipIt knows how to broadcast itself.
			[arguments addObject:jobLabel];

			[arguments addObject:requestURL.path];
			[arguments addObject:readyURL.path];

			NSMutableDictionary *jobDict = [self jobDictionaryWithLabel:jobLabel command:@"shipit-installer" arguments:arguments];
			jobDict[@(LAUNCH_JOBKEY_KEEPALIVE)] = @{
				@(LAUNCH_JOBKEY_KEEPALIVE_SUCCESSFULEXIT): @NO
			};

			jobDict[@(LAUNCH_JOBKEY_STANDARDOUTPATH)] = [appSupportURL URLByAppendingPathComponent:@"ShipIt_stdout.log"].path;
			jobDict[@(LAUNCH_JOBKEY_STANDARDERRORPATH)] = [appSupportURL URLByAppendingPathComponent:@"ShipIt_stderr.log"].path;

			#if DEBUG
			jobDict[@(LAUNCH_JOBKEY_DEBUG)] = @YES;
			#endif
			
			return jobDict;
		}]
		setNameWithFormat:@"+shipItJobDictionary"];
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

- (instancetype)initForPrivileged:(BOOL)privileged {
	self = [self init];
	if (self == nil) return nil;

	_privileged = privileged;

	return self;
}

- (RACSignal *)sendRequest:(SQRLShipItRequest *)request {
	SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:self.class.shipItJobLabel];

	return [[[RACSignal
		zip:@[
			directoryManager.shipItStateURL,
			[self waitFileLocation],
		] reduce:^(NSURL *requestURL, NSURL *readyURL) {
			RACSignal *submitJobs = [[self
				submitWatcherJobForRequestURL:requestURL readyURL:readyURL]
				concat:[self submitInstallerJobForRequestURL:requestURL readyURL:readyURL]];

			return [[request
				writeToURL:requestURL]
				concat:submitJobs];
		}]
		flatten]
		setNameWithFormat:@"%@ -sendRequest: %@", self, request];
}

- (RACSignal *)waitFileLocation {
	return [[[[RACSignal
		defer:^{
			NSURL *temporaryDirectory = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:@"com.github.Squirrel"];
			NSURL *waitFilesLocation = [temporaryDirectory URLByAppendingPathComponent:@"wait"];
			return [RACSignal return:waitFilesLocation];
		}]
		try:^(NSURL *waitDirectory, NSError **errorRef) {
			return [NSFileManager.defaultManager createDirectoryAtURL:waitDirectory withIntermediateDirectories:YES attributes:nil error:errorRef];
		}]
		map:^(NSURL *waitDirectory) {
			NSProcessInfo *processInfo = NSProcessInfo.processInfo;
			NSString *waitFileName = [processInfo.processName stringByAppendingFormat:@"-%@", processInfo.globallyUniqueString];
			return [waitDirectory URLByAppendingPathComponent:waitFileName];
		}]
		setNameWithFormat:@"%@ waitFileLocation", self];
}

- (RACSignal *)submitWatcherJobForRequestURL:(NSURL *)requestURL readyURL:(NSURL *)readyURL {
	NSDictionary *job = [self.class shipItWatcherJobDictionaryWithRequestURL:requestURL readyURL:readyURL];
	return [[self
		submitJob:job domain:(__bridge id)kSMDomainUserLaunchd authorization:nil]
		setNameWithFormat:@"%@ -submitWatcherJobForRequestURL: %@ readyURL: %@", self, requestURL, readyURL];
}

- (RACSignal *)submitInstallerJobForRequestURL:(NSURL *)requestURL readyURL:(NSURL *)readyURL {
	RACTuple *domainAuthorization = (self.privileged ? RACTuplePack((__bridge id)kSMDomainSystemLaunchd, self.class.shipItAuthorization) : RACTuplePack((__bridge id)kSMDomainUserLaunchd, [RACSignal return:nil]));

	return [[[RACSignal
		zip:@[
			[self.class shipItInstallerJobDictionaryWithRequestURL:requestURL readyURL:readyURL],
			domainAuthorization[1],
		] reduce:^(NSDictionary *job, SQRLAuthorization *authorization) {
			return [self submitJob:job domain:domainAuthorization[0] authorization:authorization];
		}]
		flatten]
		setNameWithFormat:@"%@ -submitInstallerJobForRequestURL: %@ readyURL: %@", self, requestURL, readyURL];
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
