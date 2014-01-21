//
//  RACSignal+SQRLFileManagerExtensions.h
//  Squirrel
//
//  Created by Keith Duncan on 21/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import <ReactiveCocoa/ReactiveCocoa.h>

@interface RACSignal (SQRLFileManagerExtensions)

- (RACSignal *)sqrl_tryCreateDirectory;

@end
