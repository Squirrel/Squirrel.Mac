//
//  SQRLShipItRequest.m
//  Squirrel
//
//  Created by Keith Duncan on 08/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLShipItRequest.h"

#import <ReactiveObjC/EXTKeyPathCoding.h>
#import <ReactiveObjC/EXTScope.h>
#import <ReactiveObjC/RACDisposable.h>
#import <ReactiveObjC/RACSignal+Operations.h>
#import <ReactiveObjC/RACScheduler.h>
#import <ReactiveObjC/RACSubscriber.h>
#import <ReactiveObjC/RACUnit.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

NSString * const SQRLShipItRequestErrorDomain = @"SQRLShipItRequestErrorDomain";

NSString * const SQRLShipItRequestPropertyErrorKey = @"SQRLShipItRequestPropertyErrorKey";

@interface SQRLShipItRequest () <MTLJSONSerializing>
@end

@implementation SQRLShipItRequest

#pragma mark Lifecycle

- (id)initWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
	self = [super initWithDictionary:dictionary error:error];
	if (self == nil) return nil;

	BOOL (^validateKey)(NSString *) = ^(NSString *key) {
		if ([self valueForKey:key] != nil) return YES;

		if (error != NULL) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Missing required value", nil),
				NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"\"%@\" must not be set to nil.", nil), key]
			};

			*error = [NSError errorWithDomain:SQRLShipItRequestErrorDomain code:SQRLShipItRequestErrorMissingRequiredProperty userInfo:userInfo];
		}

		return NO;
	};

	if (!validateKey(@keypath(self.targetBundleURL))) return nil;
	if (!validateKey(@keypath(self.updateBundleURL))) return nil;

	return self;
}

- (instancetype)initWithUpdateBundleURL:(NSURL *)updateBundleURL targetBundleURL:(NSURL *)targetBundleURL bundleIdentifier:(NSString *)bundleIdentifier launchAfterInstallation:(BOOL)launchAfterInstallation useUpdateBundleName:(BOOL)useUpdateBundleName {
	return [self initWithUpdateBundleURL:updateBundleURL targetBundleURL:targetBundleURL bundleIdentifier:bundleIdentifier launchAfterInstallation:launchAfterInstallation useUpdateBundleName:useUpdateBundleName earlyStaging:NO];
}

- (instancetype)initWithUpdateBundleURL:(NSURL *)updateBundleURL targetBundleURL:(NSURL *)targetBundleURL bundleIdentifier:(NSString *)bundleIdentifier launchAfterInstallation:(BOOL)launchAfterInstallation useUpdateBundleName:(BOOL)useUpdateBundleName earlyStaging:(BOOL)earlyStaging {
	return [self initWithDictionary:@{
		@keypath(self.updateBundleURL): updateBundleURL,
		@keypath(self.targetBundleURL): targetBundleURL,
		@keypath(self.bundleIdentifier): bundleIdentifier ?: NSNull.null,
		@keypath(self.launchAfterInstallation): @(launchAfterInstallation),
		@keypath(self.useUpdateBundleName): @(useUpdateBundleName),
		@keypath(self.earlyStaging): @(earlyStaging),
	} error:NULL];
}

#pragma mark Serialization

+ (NSDictionary *)JSONKeyPathsByPropertyKey {
	return @{
		@keypath(SQRLShipItRequest.new, updateBundleURL): @keypath(SQRLShipItRequest.new, updateBundleURL),
		@keypath(SQRLShipItRequest.new, targetBundleURL): @keypath(SQRLShipItRequest.new, targetBundleURL),
		@keypath(SQRLShipItRequest.new, bundleIdentifier): @keypath(SQRLShipItRequest.new, bundleIdentifier),
		@keypath(SQRLShipItRequest.new, launchAfterInstallation): @keypath(SQRLShipItRequest.new, launchAfterInstallation),
		@keypath(SQRLShipItRequest.new, useUpdateBundleName): @keypath(SQRLShipItRequest.new, useUpdateBundleName),
		@keypath(SQRLShipItRequest.new, earlyStaging): @keypath(SQRLShipItRequest.new, earlyStaging),
		@keypath(SQRLShipItRequest.new, preparationError): @keypath(SQRLShipItRequest.new, preparationError),
	};
}

- (BOOL)matchesPreparedRequest:(SQRLShipItRequest *)request {
	if (request == nil) return NO;
	return [self.updateBundleURL isEqual:request.updateBundleURL] &&
		[self.targetBundleURL isEqual:request.targetBundleURL] &&
		(self.bundleIdentifier == request.bundleIdentifier || [self.bundleIdentifier isEqual:request.bundleIdentifier]) &&
		self.useUpdateBundleName == request.useUpdateBundleName &&
		self.earlyStaging == request.earlyStaging;
}

+ (NSURL *)preparationStatusURLForStateURL:(NSURL *)stateURL {
	NSParameterAssert(stateURL != nil);
	return [stateURL URLByAppendingPathExtension:@"prepared"];
}

+ (RACSignal *)watchDirectoryAtURL:(NSURL *)directoryURL {
	NSParameterAssert(directoryURL != nil);

	return [[RACSignal createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
		int dirfd = open(directoryURL.path.fileSystemRepresentation, O_EVTONLY | O_CLOEXEC);
		if (dirfd < 0) {
			return [[[RACSignal interval:1.0 onScheduler:[RACScheduler schedulerWithPriority:RACSchedulerPriorityLow]]
				startWith:NSDate.date]
				subscribe:subscriber];
		}

		dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
		dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)dirfd, DISPATCH_VNODE_WRITE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_ATTRIB, queue);
		if (source == nil) {
			close(dirfd);
			return [[[RACSignal interval:1.0 onScheduler:[RACScheduler schedulerWithPriority:RACSchedulerPriorityLow]]
				startWith:NSDate.date]
				subscribe:subscriber];
		}

		dispatch_source_set_event_handler(source, ^{
			[subscriber sendNext:RACUnit.defaultUnit];
		});
		dispatch_source_set_cancel_handler(source, ^{
			close(dirfd);
		});
		[subscriber sendNext:RACUnit.defaultUnit];
		dispatch_resume(source);

		return [RACDisposable disposableWithBlock:^{
			dispatch_source_cancel(source);
		}];
	}] setNameWithFormat:@"+watchDirectoryAtURL: %@", directoryURL];
}

- (RACSignal *)writePreparationResult:(NSError *)error usingURL:(RACSignal *)stateURL {
	NSParameterAssert(stateURL != nil);

	return [stateURL flattenMap:^(NSURL *URL) {
		NSURL *preparedURL = [SQRLShipItRequest preparationStatusURLForStateURL:URL];
		NSMutableDictionary *values = [self.dictionaryValue mutableCopy];
		values[@keypath(self.preparationError)] = error.localizedDescription ?: NSNull.null;
		NSError *modelError = nil;
		SQRLShipItRequest *updated = [[SQRLShipItRequest alloc] initWithDictionary:values error:&modelError];
		if (updated == nil) return [RACSignal error:modelError];

		return [[updated serialization] flattenMap:^(NSData *data) {
			NSError *writeError = nil;
			if (![updated writePreparationData:data toURL:preparedURL error:&writeError]) {
				NSDictionary *userInfo = @{
					NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write update request", nil),
					NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"An unknown error occurred while archiving.", nil),
				};
				if (writeError != nil) {
					userInfo = [userInfo mtl_dictionaryByAddingEntriesFromDictionary:@{
						NSUnderlyingErrorKey: writeError,
					}];
				}
				return [RACSignal error:[NSError errorWithDomain:SQRLShipItRequestErrorDomain code:SQRLShipItRequestErrorArchiving userInfo:userInfo]];
			}
			return [RACSignal empty];
		}];
	}];
}

- (BOOL)writePreparationData:(NSData *)data toURL:(NSURL *)URL error:(NSError **)errorRef {
	NSURL *parentURL = URL.URLByDeletingLastPathComponent;
	NSString *fileName = URL.lastPathComponent;

	// ShipIt may run as root while writing into the user's cache directory.
	// Reject symlinks on the directory (and all ancestor components when
	// privileged), create a fresh mode-0644 temporary file with O_NOFOLLOW,
	// and renameat() within the opened directory descriptor so symlinks are
	// never followed.
	int dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
	if (geteuid() == 0) {
		dirFlags |= O_NOFOLLOW_ANY;
	}
	int dirfd = open(parentURL.path.fileSystemRepresentation, dirFlags);
	if (dirfd < 0) {
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
		return NO;
	}
	@onExit {
		close(dirfd);
	};

	struct stat dirStat;
	if (fstat(dirfd, &dirStat) != 0 || !S_ISDIR(dirStat.st_mode)) {
		int code = errno ?: ENOTDIR;
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
		return NO;
	}

	NSString *tempName = [NSString stringWithFormat:@".%@.%@", fileName, NSUUID.UUID.UUIDString];
	int fd = openat(dirfd, tempName.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
	if (fd < 0) {
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
		return NO;
	}

	if (fchmod(fd, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH) != 0) {
		int code = errno;
		close(fd);
		unlinkat(dirfd, tempName.fileSystemRepresentation, 0);
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
		return NO;
	}

	const uint8_t *bytes = data.bytes;
	NSUInteger remaining = data.length;
	while (remaining > 0) {
		ssize_t written = write(fd, bytes, remaining);
		if (written < 0) {
			if (errno == EINTR) continue;
			int code = errno;
			close(fd);
			unlinkat(dirfd, tempName.fileSystemRepresentation, 0);
			if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
			return NO;
		}
		bytes += written;
		remaining -= (NSUInteger)written;
	}

	if (close(fd) != 0) {
		int code = errno;
		unlinkat(dirfd, tempName.fileSystemRepresentation, 0);
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
		return NO;
	}

	__block BOOL renamed = NO;
	__block NSError *renameError = nil;
	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateWritingItemAtURL:URL options:0 error:&renameError byAccessor:^(NSURL * __unused newURL) {
		if (renameat(dirfd, tempName.fileSystemRepresentation, dirfd, fileName.fileSystemRepresentation) == 0) {
			renamed = YES;
		} else {
			renameError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
		}
	}];

	if (!renamed) {
		unlinkat(dirfd, tempName.fileSystemRepresentation, 0);
		if (errorRef != NULL) *errorRef = renameError;
		return NO;
	}

	return YES;
}

- (RACSignal *)waitForPreparationUsingURL:(RACSignal *)stateURL {
	NSParameterAssert(stateURL != nil);

	RACScheduler *scheduler = [RACScheduler scheduler];
	return [[[stateURL
		flattenMap:^(NSURL *URL) {
			NSURL *preparedURL = [SQRLShipItRequest preparationStatusURLForStateURL:URL];
			RACSignal *preparedURLSignal = [RACSignal return:preparedURL];
			return [[[[SQRLShipItRequest watchDirectoryAtURL:preparedURL.URLByDeletingLastPathComponent]
				flattenMap:^(id _) {
					return [[SQRLShipItRequest readUsingURL:preparedURLSignal] catchTo:[RACSignal empty]];
				}]
				flattenMap:^(SQRLShipItRequest *preparedRequest) {
					if (![self matchesPreparedRequest:preparedRequest]) return [RACSignal empty];
					if (preparedRequest.preparationError != nil) {
						return [RACSignal error:[NSError errorWithDomain:SQRLShipItRequestErrorDomain code:SQRLShipItRequestErrorUnarchiving userInfo:@{ NSLocalizedDescriptionKey: preparedRequest.preparationError }]];
					}
					return [RACSignal return:preparedRequest];
				}]
				take:1];
		}]
		take:1]
		timeout:300 onScheduler:scheduler];
}

+ (NSValueTransformer *)updateBundleURLJSONTransformer {
	return [NSValueTransformer valueTransformerForName:MTLURLValueTransformerName];
}

+ (NSValueTransformer *)targetBundleURLJSONTransformer {
	return [NSValueTransformer valueTransformerForName:MTLURLValueTransformerName];
}

+ (RACSignal *)readUsingURL:(RACSignal *)URL {
	NSParameterAssert(URL != nil);

	return [[[[URL
		flattenMap:^(NSURL *stateURL) {
			NSError *error;
			NSData *data = [self readFromURL:stateURL error:&error];
			if (data == nil) {
				return [RACSignal error:error];
			}

			return [RACSignal return:data];
		}]
		flattenMap:^(NSData *data) {
			return [self readFromData:data];
		}]
		catch:^(NSError *error) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Could not read update request", nil),
			};
			if (error != nil) {
				userInfo = [userInfo mtl_dictionaryByAddingEntriesFromDictionary:@{
					NSUnderlyingErrorKey: error,
				}];
			}
			return [RACSignal error:[NSError errorWithDomain:SQRLShipItRequestErrorDomain code:SQRLShipItRequestErrorUnarchiving userInfo:userInfo]];
		}]
		setNameWithFormat:@"+readUsingURL: %@", URL];
}

+ (NSData *)readFromURL:(NSURL *)URL error:(NSError **)errorRef {
	__block NSData *data = nil;

	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateReadingItemAtURL:URL options:NSFileCoordinatorReadingWithoutChanges error:errorRef byAccessor:^(NSURL *newURL) {
		data = [NSData dataWithContentsOfURL:newURL options:NSDataReadingUncached error:errorRef];
	}];

	return data;
}

+ (RACSignal *)readFromData:(NSData *)data {
	return [[RACSignal
		defer:^{
			NSError *error;
			NSDictionary *JSONDictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
			if (JSONDictionary == nil) {
				return [RACSignal error:error];
			}

			SQRLShipItRequest *request = [MTLJSONAdapter modelOfClass:SQRLShipItRequest.class fromJSONDictionary:JSONDictionary error:&error];
			if (request == nil) {
				return [RACSignal error:error];
			}

			return [RACSignal return:request];

		}]
		setNameWithFormat:@"+readFromData: <NSData %p>", data];
}

- (RACSignal *)writeUsingURL:(RACSignal *)URL {
	NSParameterAssert(URL != nil);

	return [[[[RACSignal
		zip:@[
			URL,
			[self serialization]
		] reduce:^(NSURL *stateURL, NSData *data) {
			NSError *error;
			BOOL write = [self writeData:data toURL:stateURL error:&error];
			if (!write) {
				return [RACSignal error:error];
			}

			return [RACSignal empty];
		}]
		flatten]
		catch:^(NSError *error) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write update request", nil),
				NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"An unknown error occurred while archiving.", nil),
			};
			if (error != nil) {
				userInfo = [userInfo mtl_dictionaryByAddingEntriesFromDictionary:@{
					NSUnderlyingErrorKey: error,
				}];
			}
			return [RACSignal error:[NSError errorWithDomain:SQRLShipItRequestErrorDomain code:SQRLShipItRequestErrorArchiving userInfo:userInfo]];
		}]
		setNameWithFormat:@"%@ -writeUsingURL: %@", self, URL];
}

- (BOOL)writeData:(NSData *)data toURL:(NSURL *)URL error:(NSError **)errorRef {
	__block BOOL success = NO;

	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateWritingItemAtURL:URL options:0 error:errorRef byAccessor:^(NSURL *newURL) {
		success = [data writeToURL:newURL options:NSDataWritingAtomic error:errorRef];
	}];

	return success;
}

- (RACSignal *)serialization {
	return [[RACSignal
		defer:^{
			NSError *error;
			NSDictionary *JSONDictionary = [MTLJSONAdapter JSONDictionaryFromModel:self error:&error];
			if (JSONDictionary == nil) {
				return [RACSignal error:error];
			}

			NSData *data = [NSJSONSerialization dataWithJSONObject:JSONDictionary options:0 error:&error];
			if (data == nil) {
				return [RACSignal error:error];
			}

			return [RACSignal return:data];
		}]
		setNameWithFormat:@"%@ serialization", self];
}

@end
