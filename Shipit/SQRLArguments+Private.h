//
//  SQRLArguments+Private.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLArguments.h"

#if DEBUG

// Specified for SQRLShipItCommandKey to immediately install an update bundle,
// without waiting for process termination. Uses the following keys:
//
//  - SQRLTargetBundleURLKey
//  - SQRLUpdateBundleURLKey
//  - SQRLBackupURLKey
#define SQRLShipItInstallWithoutWaitingCommand "SQRLShipItInstallWithoutWaitingCommand"

#endif
