//
//  SQRLDownloaderSpec.m
//  Squirrel
//
//  Copyright (c) 2026 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveObjC/ReactiveObjC.h>
#import <Squirrel/Squirrel.h>

#import "QuickSpec+SQRLFixtures.h"

QuickSpecBegin(SQRLDownloaderSpec)

static const NSUInteger payloadLength = 4 * 1024 * 1024;

__block NSData *payload;
__block NSURL *serverURL;
__block NSURL *requestLogURL;
__block NSURL *resumeDataURL;
__block NSURL *destinationURL;

NSArray * (^requestLog)(void) = ^{
	NSString *log = [NSString stringWithContentsOfURL:requestLogURL encoding:NSUTF8StringEncoding error:NULL];
	return [[log componentsSeparatedByString:@"\n"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
};

SQRLDownloader * (^downloaderForPath)(NSString *) = ^(NSString *path) {
	NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:path relativeToURL:serverURL]];
	return [[SQRLDownloader alloc] initWithRequest:request resumeDataURL:resumeDataURL];
};

beforeEach(^{
	NSMutableData *bytes = [NSMutableData dataWithLength:payloadLength];
	arc4random_buf(bytes.mutableBytes, bytes.length);
	payload = bytes;

	NSURL *serveDirectoryURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"serve"];
	expect(@([NSFileManager.defaultManager createDirectoryAtURL:serveDirectoryURL withIntermediateDirectories:YES attributes:nil error:NULL])).to(beTruthy());
	expect(@([payload writeToURL:[serveDirectoryURL URLByAppendingPathComponent:@"payload.zip"] atomically:YES])).to(beTruthy());
	expect(@([payload writeToURL:[serveDirectoryURL URLByAppendingPathComponent:@"other.zip"] atomically:YES])).to(beTruthy());

	serverURL = [self startTestServerForDirectory:serveDirectoryURL requestLog:&requestLogURL];
	resumeDataURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"download.resumedata"];
	destinationURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"downloaded.zip"];
});

it(@"should stream the payload to the destination and report progress", ^{
	SQRLDownloader *downloader = downloaderForPath(@"payload.zip");

	NSMutableArray *progress = [NSMutableArray array];
	[downloader.progress subscribeNext:^(SQRLDownloadProgress *value) {
		@synchronized (progress) {
			[progress addObject:value];
		}
	}];

	NSError *error;
	RACTuple *result = [[downloader downloadToURL:destinationURL] firstOrDefault:nil success:NULL error:&error];
	expect(error).to(beNil());
	expect(result.second).to(equal(destinationURL));
	expect(@([(NSHTTPURLResponse *)result.first statusCode])).to(equal(@200));
	expect([NSData dataWithContentsOfURL:destinationURL]).to(equal(payload));

	SQRLDownloadProgress *last = progress.lastObject;
	expect(@(last.bytesResumed)).to(equal(@0));
	expect(@(last.bytesReceived)).to(equal(@(payloadLength)));
	expect(@(last.bytesExpected)).to(equal(@(payloadLength)));
	expect(@([NSFileManager.defaultManager fileExistsAtPath:resumeDataURL.path])).to(beFalsy());
});

it(@"should continue an interrupted transfer from where it stopped", ^{
	NSError *error;
	BOOL finished = [[downloaderForPath(@"payload.zip?drop=1048576") downloadToURL:destinationURL] waitUntilCompleted:&error];
	expect(@(finished)).to(beFalsy());
	expect(error.domain).to(equal(NSURLErrorDomain));
	expect(@([NSFileManager.defaultManager fileExistsAtPath:resumeDataURL.path])).to(beTruthy());

	SQRLDownloader *downloader = downloaderForPath(@"payload.zip?drop=1048576");
	__block SQRLDownloadProgress *lastProgress;
	[downloader.progress subscribeNext:^(SQRLDownloadProgress *value) {
		lastProgress = value;
	}];

	error = nil;
	RACTuple *result = [[downloader downloadToURL:destinationURL] firstOrDefault:nil success:NULL error:&error];
	expect(error).to(beNil());
	expect(@([(NSHTTPURLResponse *)result.first statusCode])).to(equal(@206));
	expect([NSData dataWithContentsOfURL:destinationURL]).to(equal(payload));

	expect(@(lastProgress.bytesResumed)).to(beGreaterThan(@0));
	expect(@(lastProgress.bytesReceived)).to(equal(@(payloadLength)));
	expect(requestLog().lastObject).to(beginWith([NSString stringWithFormat:@"GET /payload.zip Range=bytes=%lld-", lastProgress.bytesResumed]));
	expect(@([NSFileManager.defaultManager fileExistsAtPath:resumeDataURL.path])).to(beFalsy());
});

it(@"should go back to a plain GET when the resumed request is refused or reset", ^{
	for (NSString *ranged in @[ @"403", @"reset" ]) {
		NSString *path = [NSString stringWithFormat:@"payload.zip?drop=1048576&ranged=%@", ranged];
		[[downloaderForPath(path) downloadToURL:destinationURL] waitUntilCompleted:NULL];
		expect(@([NSFileManager.defaultManager fileExistsAtPath:resumeDataURL.path])).to(beTruthy());

		NSError *error;
		RACTuple *result = [[downloaderForPath(path) downloadToURL:destinationURL] firstOrDefault:nil success:NULL error:&error];
		expect(error).to(beNil());
		expect(@([(NSHTTPURLResponse *)result.first statusCode])).to(equal(@200));
		expect([NSData dataWithContentsOfURL:destinationURL]).to(equal(payload));

		NSArray *log = requestLog();
		expect(log[log.count - 2]).to(beginWith(@"GET /payload.zip Range=bytes="));
		expect(log.lastObject).to(equal(@"GET /payload.zip Range=- If-Range=-"));
		expect(@([NSFileManager.defaultManager fileExistsAtPath:resumeDataURL.path])).to(beFalsy());
	}
});

it(@"should put the resume data back when the network is gone rather than the range refused", ^{
	NSString *path = @"payload.zip?drop=1048576&then=reset";
	[[downloaderForPath(path) downloadToURL:destinationURL] waitUntilCompleted:NULL];
	NSData *stored = [NSData dataWithContentsOfURL:resumeDataURL];
	expect(stored).notTo(beNil());

	NSError *error;
	BOOL finished = [[downloaderForPath(path) downloadToURL:destinationURL] waitUntilCompleted:&error];
	expect(@(finished)).to(beFalsy());
	expect(error.domain).to(equal(NSURLErrorDomain));

	NSArray *log = requestLog();
	expect([log filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'GET /payload.zip Range=bytes='"]]).notTo(beEmpty());
	expect(log.lastObject).to(equal(@"GET /payload.zip Range=- If-Range=-"));
	expect([NSData dataWithContentsOfURL:resumeDataURL]).to(equal(stored));
});

it(@"should hold no resume data on disk while a resumed download owns the partial file", ^{
	NSString *path = @"payload.zip?drop=1048576&slow=20&ranged=slow";
	[[downloaderForPath(path) downloadToURL:destinationURL] waitUntilCompleted:NULL];
	expect(@([NSFileManager.defaultManager fileExistsAtPath:resumeDataURL.path])).to(beTruthy());

	__block BOOL done = NO;
	SQRLDownloader *downloader = downloaderForPath(path);
	[[downloader downloadToURL:destinationURL] subscribeError:^(NSError *error) {
		done = YES;
	} completed:^{
		done = YES;
	}];

	expect(@([[downloader.progress take:2] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
	expect(@(done)).to(beFalsy());
	expect(@([NSFileManager.defaultManager fileExistsAtPath:resumeDataURL.path])).to(beFalsy());

	expect(@(done)).withTimeout(30).toEventually(beTruthy());
	expect([NSData dataWithContentsOfURL:destinationURL]).to(equal(payload));
});

it(@"should keep resume data when the download is disposed of", ^{
	SQRLDownloader *downloader = downloaderForPath(@"payload.zip?slow=20");
	RACDisposable *disposable = [[downloader downloadToURL:destinationURL] subscribeCompleted:^{}];

	// Let some bytes arrive, then walk away as a caller losing interest would.
	expect(@([[downloader.progress take:1] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());
	[disposable dispose];

	expect(@([NSFileManager.defaultManager fileExistsAtPath:resumeDataURL.path])).toEventually(beTruthy());
});

it(@"should start over when the resume data belongs to another URL", ^{
	[[downloaderForPath(@"payload.zip?drop=1048576") downloadToURL:destinationURL] waitUntilCompleted:NULL];
	expect(@([NSFileManager.defaultManager fileExistsAtPath:resumeDataURL.path])).to(beTruthy());

	NSError *error;
	BOOL finished = [[downloaderForPath(@"other.zip") downloadToURL:destinationURL] waitUntilCompleted:&error];
	expect(@(finished)).to(beTruthy());
	expect(error).to(beNil());
	expect([NSData dataWithContentsOfURL:destinationURL]).to(equal(payload));
	expect(requestLog().lastObject).to(equal(@"GET /other.zip Range=- If-Range=-"));
});

it(@"should hand +cancelAllWritingResumeDataWithTimeout: the resume data of in-flight downloads", ^{
	SQRLDownloader *downloader = downloaderForPath(@"payload.zip?slow=20");
	[[downloader downloadToURL:destinationURL] subscribeCompleted:^{}];
	expect(@([[downloader.progress take:1] asynchronouslyWaitUntilCompleted:NULL])).to(beTruthy());

	[SQRLDownloader cancelAllWritingResumeDataWithTimeout:10];
	expect(@([NSFileManager.defaultManager fileExistsAtPath:resumeDataURL.path])).to(beTruthy());
});

QuickSpecEnd
