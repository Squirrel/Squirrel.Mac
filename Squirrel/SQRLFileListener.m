//
//  SQRLFileListener.m
//  Squirrel
//
//  Created by Keith Duncan on 17/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLFileListener.h"

#import <ReactiveCocoa/ReactiveCocoa.h>

#import <dirent.h>

@implementation SQRLFileListener

+ (RACSignal *)waitUntilItemExistsAtFileURL:(NSURL *)fileURL {
	NSParameterAssert(fileURL != nil);

	return [[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			NSURL *parentDirectory = fileURL.URLByDeletingLastPathComponent;

			void (^sendErrno)(void) = ^{
				NSDictionary *errorInfo = @{
					NSURLErrorKey: fileURL,
				};
				[subscriber sendError:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:errorInfo]];
			};

			DIR *directory = opendir(parentDirectory.path.fileSystemRepresentation);
			if (directory == NULL) {
				sendErrno();
				return nil;
			}

			int fileDescriptor = dirfd(directory);
			if (fileDescriptor == -1) {
				sendErrno();
				return nil;
			}

			void (^checkExists)(void) = ^{
				BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:fileURL.path isDirectory:NULL];
				if (!exists) return;

				[subscriber sendCompleted];
			};

			dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fileDescriptor, DISPATCH_VNODE_WRITE, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
			dispatch_source_set_cancel_handler(source, ^{
				closedir(directory);
			});
			dispatch_source_set_event_handler(source, ^{
				checkExists();
			});
			dispatch_resume(source);

			checkExists();

			return [RACDisposable disposableWithBlock:^{
				dispatch_source_cancel(source);
				dispatch_release(source);
			}];
		}]
		setNameWithFormat:@"waitUntilItemExistsAtFileURL: %@", fileURL];
}

@end
