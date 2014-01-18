//
//  SQRLFileListener.m
//  Squirrel
//
//  Created by Keith Duncan on 17/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLFileListener.h"

#import <ReactiveCocoa/ReactiveCocoa.h>

@interface SQRLFileListener ()
@property (readwrite, strong, nonatomic) RACSignal *waitUntilPresent;
@end

@implementation SQRLFileListener

- (instancetype)initWithFileURL:(NSURL *)fileURL {
	self = [self init];
	if (self == nil) return nil;

	_waitUntilPresent = [[RACSignal
		createSignal:^(id<RACSubscriber> subscriber) {
			NSURL *parentDirectory = fileURL.URLByDeletingLastPathComponent;

			int fileDescriptor = open(parentDirectory.fileSystemRepresentation, O_RDONLY);

			void (^checkExists)(void) = ^{
				BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:fileURL.path isDirectory:NULL];
				if (!exists) return;

				[subscriber sendCompleted];
			};

			dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fileDescriptor, DISPATCH_VNODE_WRITE, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
			dispatch_source_set_cancel_handler(source, ^{
				close(fileDescriptor);
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
		setNameWithFormat:@"%@ -present", self];

	return self;
}

@end
