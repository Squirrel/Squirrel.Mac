//
//  SQRLInstallerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

SpecBegin(SQRLInstaller)

__block NSURL *updateURL;
__block xpc_connection_t shipitConnection;

beforeEach(^{
	updateURL = [self createTestApplicationUpdate];
	shipitConnection = [self connectToShipIt];
});

it(@"should install an update", ^{
	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(message, SQRLShipItCommandKey, SQRLShipItInstallWithoutWaitingCommand);

	xpc_dictionary_set_string(message, SQRLTargetBundleURLKey, self.testApplicationBundle.bundleURL.absoluteString.UTF8String);
	xpc_dictionary_set_string(message, SQRLUpdateBundleURLKey, updateURL.absoluteString.UTF8String);
	xpc_dictionary_set_string(message, SQRLBackupURLKey, self.temporaryDirectoryURL.absoluteString.UTF8String);

	expect(self.testApplicationBundle.infoDictionary[SQRLBundleShortVersionStringKey]).to.equal(SQRLTestApplicationOriginalShortVersionString);

	__block BOOL installed = NO;

	xpc_connection_send_message_with_reply(shipitConnection, message, dispatch_get_main_queue(), ^(xpc_object_t event) {
		expect(xpc_dictionary_get_bool(event, SQRLShipItSuccessKey)).to.beTruthy();
		expect(xpc_dictionary_get_string(event, SQRLShipItErrorKey)).to.beNil();

		installed = YES;
	});

	expect(installed).will.beTruthy();
	expect(self.testApplicationBundle.infoDictionary[SQRLBundleShortVersionStringKey]).to.equal(SQRLTestApplicationUpdatedShortVersionString);
});

SpecEnd
