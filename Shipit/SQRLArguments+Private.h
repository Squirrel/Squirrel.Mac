//
//  SQRLArguments+Private.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLArguments.h"

// The label for the test XPC service.
#define SQRLTestXPCServiceLabel "com.github.Squirrel.TestService"

// Specified for SQRLShipItCommandKey to connect to the endpoint in
// SQRLShipItEndpointKey and listen for further commands.
#define SQRLShipItConnectToEndpointCommand "SQRLShipItConnectToEndpointCommand"

// An XPC event key, associated with an xpc_endpoint_t for connecting the ShipIt
// service to unit tests (and vice-versa).
#define SQRLShipItEndpointKey "SQRLShipitEndpointKey"

// Specified for SQRLShipItCommandKey to listen for termination of the parent
// process.
#define SQRLShipItListenForTerminationCommand "SQRLShipItListenForTerminationCommand"
