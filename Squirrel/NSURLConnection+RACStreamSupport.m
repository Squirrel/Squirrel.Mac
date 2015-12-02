//
//  NSURLConnection+RACStreamSupport
//  ReactiveCocoa
//
//  Created by Antoine Duchâteay on 2015-11-3°.
//  Copyright (c) 2013 Taktik SA, Inc. All rights reserved.
//

#import "NSURLConnection+RACStreamSupport.h"

@interface RACNSURLConnectionDataDelegate : NSObject<NSURLConnectionDataDelegate>
@property (strong, readwrite) NSString * fileName;
@property (strong, readwrite) NSFileHandle * file;
@property (strong, readwrite) NSURLResponse * response;
@property (strong, readwrite) void(^handler)(NSURLResponse* __nullable response, NSString * __nullable fileName, NSError* __nullable connectionError);

- (void) cleanup;
@end

@implementation RACNSURLConnectionDataDelegate
- (instancetype) initWithFileName:(NSString *)fileName completionHandler:(void (^)(NSURLResponse* __nullable response, NSString * __nullable fileName, NSError* __nullable connectionError)) handler {
    if (self = [super init]) {
        self.fileName = fileName;
        self.handler = handler;
    }
    return self;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse*)response {
    self.response = response;
    
    if (response.suggestedFilename) {
        self.fileName = [self.fileName.stringByDeletingLastPathComponent stringByAppendingPathComponent:response.suggestedFilename];
    }
    
    [[NSFileManager defaultManager] createFileAtPath:self.fileName contents:nil attributes:nil];
    self.file = [NSFileHandle fileHandleForUpdatingAtPath:self.fileName];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (self.file)  {
        [self.file seekToEndOfFile];
    }
    NSLog(@"Received %lu bytes",(unsigned long)data.length);
    [self.file writeData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection { 
    [self.file closeFile];
    self.file = nil;

    self.handler(self.response, self.fileName, nil);
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    self.handler(nil, nil, error);
}

- (void) cleanup {}
@end

@implementation NSURLConnection (RACStreamSupport)

+ (RACSignal *)rac_startAsynchronousRequest:(NSURLRequest *)request into:(NSURL*)destination {
    NSCParameterAssert(request != nil);
    
    return [[RACSignal
             createSignal:^(id<RACSubscriber> subscriber) {
                 RACNSURLConnectionDataDelegate * delegate;
                 delegate = [[RACNSURLConnectionDataDelegate alloc] initWithFileName:destination.path completionHandler:^(NSURLResponse *response, NSString * fileName, NSError *error) {
                     [delegate cleanup];
                     
                     if (response == nil || error) {
                         [subscriber sendError:error];
                     } else {
                         [subscriber sendNext:RACTuplePack(response, [NSURL fileURLWithPath:fileName])];
                         [subscriber sendCompleted];
                     }
                 }];
                 
                 NSURLConnection * connection = [[NSURLConnection alloc]
                                                 initWithRequest:request
                                                 delegate:delegate startImmediately:NO];
                 
                 [connection scheduleInRunLoop:[NSRunLoop mainRunLoop]
                                       forMode:NSDefaultRunLoopMode];
                 [connection start];
                 
                 return [RACDisposable disposableWithBlock:^{
                     [connection cancel];
                 }];
             }]
            setNameWithFormat:@"+rac_startAsynchronousRequest: %@", request];
}

@end
