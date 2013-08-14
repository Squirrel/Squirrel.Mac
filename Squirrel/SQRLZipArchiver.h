//
//  SQRLZipArchiver.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-13.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// Uses `ditto` on the command line to zip and unzip archives.
@interface SQRLZipArchiver : NSObject

// Asynchronously creates a zip archive.
//
// zipArchiveURL     - The file URL at which to create the zip archive. Anything
//                     already existing at this URL will be overwritten. This
//                     must not be nil.
// directoryURL      - The directory to include in the zip archive. The name
//                     (but not path) of the directory itself will be embedded
//                     into the archive. This must not be nil.
// completionHandler - A block to invoke when zipping has succeeded or failed.
//                     This must not be nil.
+ (void)createZipArchiveAtURL:(NSURL *)zipArchiveURL fromDirectoryAtURL:(NSURL *)directoryURL completion:(void (^)(BOOL success))completionHandler;

// Asynchronously extracts a zip archive.
//
// zipArchiveURL     - The file URL of the zip archive. This must not be nil.
// directoryURL      - The directory to extract the contents of the archive to.
//                     Any files or folders that use the same name as entries in
//                     the archive will be overridden. This must not be nil.
// completionHandler - A block to invoke when unzipping has succeeded or failed.
//                     This must not be nil.
+ (void)unzipArchiveAtURL:(NSURL *)zipArchiveURL intoDirectoryAtURL:(NSURL *)directoryURL completion:(void (^)(BOOL success))completionHandler;

@end
