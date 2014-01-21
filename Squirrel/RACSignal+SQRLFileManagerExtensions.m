//
//  RACSignal+SQRLFileManagerExtensions.m
//  Squirrel
//
//  Created by Keith Duncan on 21/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "RACSignal+SQRLFileManagerExtensions.h"

@implementation RACSignal (SQRLFileManagerExtensions)

- (RACSignal *)sqrl_tryCreateDirectory {
	return [[self
		try:^(NSURL *directoryURL, NSError **errorRef) {
			return [NSFileManager.defaultManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:errorRef];
		}]
		setNameWithFormat:@"%@ -sqrl_tryCreateDirectory", self];
}

@end
