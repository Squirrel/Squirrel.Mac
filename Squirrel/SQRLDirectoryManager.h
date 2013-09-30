//
//  SQRLFileManager.h
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// Provides the file locations that Squirrel uses per application.
@interface SQRLDirectoryManager : NSObject

// Determine the current app identifier, uses bundle identifier or app name.
//
// Calls `initWithAppIdentifier:`.
+ (instancetype)directoryManagerForCurrentApplication;

// Designated initialiser.
//
// appIdentifier - Must not be nil, all files Squirrel writes are scoped per
//                 application.
- (instancetype)initWithAppIdentifier:(NSString *)appIdentifier;

// The file to store resumable download state in.
- (NSURL *)URLForResumableDownloadStateFile;

// The directory to store update downloads in prior to installation. The
// directory is created for you.
- (NSURL *)URLForDownloadDirectory;

// The directory to unpack updates into prior to to installation. The
// directory is created for you.
- (NSURL *)URLForUnpackDirectory;

@end
