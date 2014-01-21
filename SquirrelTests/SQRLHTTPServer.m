//
//  SQRLHTTPServer.m
//  Squirrel
//
//  Created by Keith Duncan on 03/12/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLHTTPServer.h"

#import <sys/socket.h>
#import <netinet/in.h>

@interface SQRLHTTPServer ()
@property (assign, nonatomic) dispatch_source_t listenerSource;
@property (strong, nonatomic) NSMutableArray *cleanupBlocks;
@end

@implementation SQRLHTTPServer

- (id)init {
	self = [super init];
	if (self == nil) return nil;

	_cleanupBlocks = [[NSMutableArray alloc] init];

	return self;
}

- (void)dealloc {
	[self invalidate];
}

- (NSURL *)start:(NSError **)errorRef {
	NSParameterAssert(self.listenerSource == NULL);

	int listenSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);

	struct sockaddr_in listenAddress = {
		.sin_len = sizeof(listenAddress),
		.sin_family = AF_INET,
		.sin_port = 0,
		.sin_addr = {
			.s_addr = htonl(INADDR_LOOPBACK),
		},
	};
	int bindError = bind(listenSocket, (struct sockaddr const *)&listenAddress, listenAddress.sin_len);
	if (bindError != 0) {
		close(listenSocket);

		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSPOSIXErrorDomain code:bindError userInfo:nil];
		return nil;
	}

	listen(listenSocket, 128);

	dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, listenSocket, 0, NULL);
	dispatch_source_set_event_handler(source, ^{
		int connectionSocket = accept(listenSocket, NULL, NULL);
		// Wait to close the connection until after the test case is complete.
		// We need NSURLConnection to timeout, closing the connection causes it
		// to error immediately.
		[self addCleanupBlock:^{
			close(connectionSocket);
		}];

		CFHTTPMessageRef request = (__bridge CFHTTPMessageRef)CFBridgingRelease(CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true));

		while (1) {
			uint8_t buffer;
			ssize_t readLength = read(connectionSocket, &buffer, 1);
			if (readLength < 0) {
				return;
			}

			CFHTTPMessageAppendBytes(request, (UInt8 const *)&buffer, readLength);
			if (!CFHTTPMessageIsHeaderComplete(request)) {
				continue;
			}

			// Doesn't support reading requests with a body for simplicity
			NSString *contentLength = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Content-Length")));
			if (contentLength != nil) {
				return;
			}

			break;
		}

		NSLog(@"Received Request:");
		NSLog(@"%@", [[NSString alloc] initWithData:CFBridgingRelease(CFHTTPMessageCopySerializedMessage(request)) encoding:NSASCIIStringEncoding]);

		CFHTTPMessageRef response = self.responseBlock(request);
		NSData *responseData = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(response));

		NSLog(@"Sending Response:");
		NSLog(@"%@", [[NSString alloc] initWithData:responseData encoding:NSASCIIStringEncoding]);

		size_t bufferLength = responseData.length;
		uint8_t const *buffer = responseData.bytes;

		while (1) {
			ssize_t writeLength = write(connectionSocket, buffer, bufferLength);
			if (writeLength < 0) {
				return;
			}

			buffer += writeLength;
			bufferLength -= writeLength;

			if (bufferLength == 0) {
				break;
			}
		}
	});
	dispatch_source_set_cancel_handler(source, ^{
		close(listenSocket);
	});
	dispatch_resume(source);

	struct sockaddr_storage localAddress = {};
	socklen_t localAddressLength = sizeof(localAddress);
	int localAddressError = getsockname(listenSocket, (struct sockaddr *)&localAddress, &localAddressLength);
	if (localAddressError != 0) {
		dispatch_release(source);

		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSPOSIXErrorDomain code:localAddressError userInfo:nil];
		return nil;
	}

	self.listenerSource = source;

	// IPv4 and IPv6 address transport layer port fields are at the same offset
	// and are the same size
	in_port_t port = ntohs(((struct sockaddr_in *)&localAddress)->sin_port);

	return [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%ld/", (unsigned long)port]];
}

- (void)invalidate {
	dispatch_source_t listenerSource = self.listenerSource;
	if (listenerSource == NULL) return;

	dispatch_source_cancel(listenerSource);
	dispatch_release(listenerSource);

	self.listenerSource = NULL;

	[self performCleanup];
}

- (void)addCleanupBlock:(void (^)(void))block {
	[self.cleanupBlocks addObject:[block copy]];
}

- (void)performCleanup {
	NSArray *blocks = [self.cleanupBlocks copy];
	[self.cleanupBlocks removeAllObjects];

	for (void (^currentBlock)(void) in blocks) {
		currentBlock();
	}
}

@end
