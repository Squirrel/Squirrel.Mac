//
//  SQRLDownloader.h
//  Squirrel
//
//  Copyright (c) 2026 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class RACSignal;

// How far an in-flight download has got.
@interface SQRLDownloadProgress : NSObject <NSCopying>

// The offset this attempt started from. Zero for a fresh download, non-zero
// when a previous partial transfer was resumed.
@property (nonatomic, assign, readonly) int64_t bytesResumed;

// Bytes on disk so far, including `bytesResumed`.
@property (nonatomic, assign, readonly) int64_t bytesReceived;

// The full size of the payload, or `NSURLSessionTransferSizeUnknown`.
@property (nonatomic, assign, readonly) int64_t bytesExpected;

- (instancetype)initWithBytesResumed:(int64_t)bytesResumed bytesReceived:(int64_t)bytesReceived bytesExpected:(int64_t)bytesExpected;

@end

// Downloads one URL to disk with an `NSURLSession` download task.
//
// The payload is streamed to a file rather than accumulated in memory. When
// the transfer fails or is cancelled and the response allows it (an `ETag` or
// `Last-Modified` validator), the session's resume data is written to
// `resumeDataURL`, and the next `SQRLDownloader` created for the same URL with
// the same `resumeDataURL` continues from that offset instead of starting
// over. This holds across process launches: the partial file lives in the
// user's temporary directory and the resume data names it. Resume data for a
// different URL, or that the session no longer accepts, is discarded and the
// download starts fresh.
//
// This is a one-shot object; create one per download.
@interface SQRLDownloader : NSObject

// The configuration new downloads create their session with. Defaults to
// `NSURLSessionConfiguration.defaultSessionConfiguration`; replace it to set
// network policy (`allowsExpensiveNetworkAccess`, proxies) or protocol
// classes. Read when a download starts.
@property (class, nonatomic, copy) NSURLSessionConfiguration *sessionConfiguration;

// request       - The request to perform. Must not be nil.
// resumeDataURL - A file URL at which resume data for `request` is kept
//                 between attempts, or nil to never resume.
- (instancetype)initWithRequest:(NSURLRequest *)request resumeDataURL:(NSURL *)resumeDataURL;

// Sends `SQRLDownloadProgress` values while a download started with
// -downloadToURL: is transferring, on an unspecified thread. Never errors;
// completes when the download does.
@property (nonatomic, strong, readonly) RACSignal *progress;

// Starts, or resumes, the download when subscribed to.
//
// destinationURL - Where to move the finished payload. Anything already there
//                  is replaced. Must not be nil.
//
// Returns a signal which sends a `RACTuple` of the final `NSURLResponse` and
// `destinationURL` then completes, or errors, on an unspecified thread. HTTP
// error statuses are not errors here; the response is passed through for the
// caller to judge. Disposing of the subscription cancels the transfer and, like
// a failure, keeps resume data for the next attempt.
- (RACSignal *)downloadToURL:(NSURL *)destinationURL;

// Cancels every download currently in flight in this process, writing resume
// data for each, and returns once that is done or `timeout` has elapsed. Meant
// for the host application's termination path so a relaunch can pick up where
// this process left off.
+ (void)cancelAllWritingResumeDataWithTimeout:(NSTimeInterval)timeout;

@end
