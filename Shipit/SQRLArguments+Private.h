//
//  SQRLArguments+Private.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLArguments.h"

// Specified for SQRLShipItCommandKey to listen for termination of a process,
// indicated using the following keys:
//
//  - SQRLProcessIdentifierKey
//  - SQRLBundleIdentifierKey
//  - SQRLTargetBundleURLKey
#define SQRLShipItListenForTerminationCommand "SQRLShipItListenForTerminationCommand"

// Specified for SQRLShipItCommandKey to immediately install an update bundle,
// without waiting for process termination. Uses the following keys:
//
//  - SQRLTargetBundleURLKey
//  - SQRLUpdateBundleURLKey
//  - SQRLBackupURLKey
#define SQRLShipItInstallWithoutWaitingCommand "SQRLShipItInstallWithoutWaitingCommand"
