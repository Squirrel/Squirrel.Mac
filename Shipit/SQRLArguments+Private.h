//
//  SQRLArguments+Private.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

// These constants are used with `shipit` over XPC to run tests that require
// certain app or process setups.
#if TESTING

// The label for the `shipit` XPC service.
#define SQRLShipitServiceLabel "com.github.Squirrel.shipit"

// The label for the test XPC service.
#define SQRLTestXPCServiceLabel "com.github.Squirrel.TestService"

// An XPC event key, associated with an xpc_endpoint_t for connecting to the
// `shipit` service.
#define SQRLShipitEndpointKey "shipitEndpoint"

// An XPC event key, associated with a string describing what the service should do.
#define SQRLCommandKey "command"

// Listens for termination of the parent process, sending an empty reply once it
// finishes.
#define SQRLCommandListenForTermination "listenForTermination"

#endif
