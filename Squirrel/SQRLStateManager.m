//
//  SQRLStateManager.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-04.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLStateManager.h"
#import "SQRLStateManager+Private.h"
#import <ReactiveCocoa/EXTScope.h>

static NSString * const SQRLTargetBundleDefaultsKey = @"TargetBundleURL";
static NSString * const SQRLUpdateBundleDefaultsKey = @"UpdateBundleURL";
static NSString * const SQRLBackupBundleDefaultsKey = @"BackupBundleURL";
static NSString * const SQRLRequirementDataDefaultsKey = @"CodeSigningRequirementData";
static NSString * const SQRLStateDefaultsKey = @"State";
static NSString * const SQRLWaitForBundleIdentifierDefaultsKey = @"WaitForBundleIdentifier";
static NSString * const SQRLShouldRelaunchDefaultsKey = @"ShouldRelaunch";
static NSString * const SQRLInstallationStateAttemptKey = @"InstallationStateAttempt";

@interface SQRLStateManager ()

// The identifier for the preferences domain to use.
@property (nonatomic, copy, readonly) NSString *applicationIdentifier;

// Use only while synchronized on `self`.
@property (nonatomic, strong, readonly) NSMutableDictionary *preferences;

@end

@implementation SQRLStateManager

#pragma mark Properties

- (NSURL *)applicationSupportURL {
	return [self.class applicationSupportURLWithIdentifier:self.applicationIdentifier];
}

- (SQRLShipItState)state {
	NSNumber *number = [self objectForKey:SQRLStateDefaultsKey ofClass:NSNumber.class];
	return number.integerValue;
}

- (void)setState:(SQRLShipItState)state {
	self[SQRLStateDefaultsKey] = @(state);
	self[SQRLInstallationStateAttemptKey] = @1;

	if (![self synchronize]) {
		NSLog(@"Failed to synchronize state for manager %@", self);
	}
}

- (NSUInteger)installationStateAttempt {
	NSNumber *number = [self objectForKey:SQRLInstallationStateAttemptKey ofClass:NSNumber.class];
	return number.unsignedIntegerValue;
}

- (void)setInstallationStateAttempt:(NSUInteger)count {
	self[SQRLInstallationStateAttemptKey] = @(count);

	if (![self synchronize]) {
		NSLog(@"Failed to synchronize state for manager %@", self);
	}
}

- (NSURL *)targetBundleURL {
	return [self fileURLForKey:SQRLTargetBundleDefaultsKey];
}

- (void)setTargetBundleURL:(NSURL *)fileURL {
	[self setFileURL:fileURL forKey:SQRLTargetBundleDefaultsKey];
}

- (NSURL *)updateBundleURL {
	return [self fileURLForKey:SQRLUpdateBundleDefaultsKey];
}

- (void)setUpdateBundleURL:(NSURL *)fileURL {
	[self setFileURL:fileURL forKey:SQRLUpdateBundleDefaultsKey];
}

- (NSURL *)backupBundleURL {
	return [self fileURLForKey:SQRLBackupBundleDefaultsKey];
}

- (void)setBackupBundleURL:(NSURL *)fileURL {
	[self setFileURL:fileURL forKey:SQRLBackupBundleDefaultsKey];
}

- (NSData *)requirementData {
	return [self objectForKey:SQRLRequirementDataDefaultsKey ofClass:NSData.class];
}

- (void)setRequirementData:(NSData *)data {
	NSParameterAssert(data == nil || [data isKindOfClass:NSData.class]);
	self[SQRLRequirementDataDefaultsKey] = data;
}

- (NSString *)waitForBundleIdentifier {
	return [self objectForKey:SQRLWaitForBundleIdentifierDefaultsKey ofClass:NSString.class];
}

- (void)setWaitForBundleIdentifier:(NSString *)identifier {
	NSParameterAssert(identifier == nil || [identifier isKindOfClass:NSString.class]);
	self[SQRLWaitForBundleIdentifierDefaultsKey] = identifier;
}

- (BOOL)relaunchAfterInstallation {
	NSNumber *number = [self objectForKey:SQRLShouldRelaunchDefaultsKey ofClass:NSNumber.class];
	return number.boolValue;
}

- (void)setRelaunchAfterInstallation:(BOOL)shouldRelaunch {
	self[SQRLShouldRelaunchDefaultsKey] = @(shouldRelaunch);
}

#pragma mark Lifecycle

- (id)initWithIdentifier:(NSString *)identifier {
	NSParameterAssert(identifier != nil);

	self = [super init];
	if (self == nil) return nil;

	_applicationIdentifier = [identifier copy];
	NSLog(@"%@ initialized", self);

	NSDictionary *existingPrefs = [NSDictionary dictionaryWithContentsOfURL:[self.class stateURLWithIdentifier:self.applicationIdentifier]];
	_preferences = [existingPrefs mutableCopy] ?: [NSMutableDictionary dictionary];

	return self;
}

- (void)dealloc {
	[self synchronize];
}

#pragma mark Generic Accessors

- (id)objectForKey:(NSString *)key ofClass:(Class)class {
	NSParameterAssert(class != nil);

	id obj = self[key];
	if (obj == nil) return nil;

	NSAssert([obj isKindOfClass:class], @"Key \"%@\" was not associated with an instance of %@: %@", key, class, obj);
	return obj;
}

- (id)objectForKeyedSubscript:(NSString *)key {
	NSParameterAssert(key != nil);

	@synchronized (self) {
		return _preferences[key];
	}
}

- (void)setObject:(id)object forKeyedSubscript:(NSString *)key {
	NSParameterAssert(key != nil);

	@synchronized (self) {
		if (object == nil) {
			[_preferences removeObjectForKey:key];
		} else {
			_preferences[key] = object;
		}
	}
}

- (NSURL *)fileURLForKey:(NSString *)key {
	NSParameterAssert(key != nil);

	NSString *path = [self objectForKey:key ofClass:NSString.class];
	if (path == nil) return nil;

	return [NSURL fileURLWithPath:path];
}

- (void)setFileURL:(NSURL *)fileURL forKey:(NSString *)key {
	NSParameterAssert(key != nil);
	NSParameterAssert(fileURL == nil || [fileURL isFileURL]);

	self[key] = fileURL.filePathURL.path;
}

#pragma mark Synchronization

+ (NSURL *)applicationSupportURLWithIdentifier:(NSString *)identifier {
	NSParameterAssert(identifier != nil);

	NSError *error = nil;
	NSURL *folderURL = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
	if (folderURL == nil) {
		NSLog(@"Could not find Application Support URL: %@", error);
		return nil;
	}

	folderURL = [folderURL URLByAppendingPathComponent:identifier];
	if (![NSFileManager.defaultManager createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:&error]) {
		NSLog(@"Could not create Application Support folder at %@: %@", folderURL, error);
		return nil;
	}

	return folderURL;
}

+ (NSURL *)stateURLWithIdentifier:(NSString *)identifier {
	return [[self applicationSupportURLWithIdentifier:identifier] URLByAppendingPathComponent:@"state.plist"];
}

+ (BOOL)clearStateWithIdentifier:(NSString *)identifier {
	NSURL *fileURL = [self stateURLWithIdentifier:identifier];
	NSError *error = nil;
	if (![NSFileManager.defaultManager removeItemAtURL:fileURL error:&error]) {
		NSLog(@"Could not remove %@: %@", fileURL, error);
	}

	return YES;
}

- (BOOL)synchronize {
	NSURL *fileURL = [self.class stateURLWithIdentifier:self.applicationIdentifier];

	@synchronized (self) {
		return [_preferences writeToURL:fileURL atomically:YES];
	}
}

#pragma mark NSObject

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p>{ applicationIdentifier: %@ }", self.class, self, self.applicationIdentifier];
}

@end
