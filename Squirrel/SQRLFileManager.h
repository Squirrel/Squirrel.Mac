//
//  SQRLFileManager.h
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// Manages the file Squirrel writes to disk per application.
@interface SQRLFileManager : NSObject

// Determine the current app identifier, uses bundle identifier or app name.
//
// Calls `fileManagerWithAppIdentifier:`.
+ (instancetype)fileManagerForCurrentApplication;

// Designated initialiser.
//
// appIdentifier - Must not be nil, all files Squirrel writes are scoped per
//                 application.
- (instancetype)initWithAppIdentifier:(NSString *)appIdentifier;

// The directory to store update downloads in prior to installation.
- (NSURL *)URLForDownloadDirectory;

// The directory to unpack updates into prior to to installation.
- (NSURL *)URLForUnpackDirectory;

@end
