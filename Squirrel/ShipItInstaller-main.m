//
//  main.m
//  shipit
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import "NSError+SQRLVerbosityExtensions.h"
#import "RACSignal+SQRLTransactionExtensions.h"
#import "SQRLCodeSignature.h"
#import "SQRLDirectoryManager.h"
#import "SQRLInstaller.h"
#import "SQRLShipItState.h"
#import "SQRLTerminationListener.h"

// The maximum number of times ShipIt should run the same installation state, in
// an attempt to update.
//
// If ShipIt is launched in the same state more than this number of times,
// updating will abort.
static const NSUInteger SQRLShipItMaximumInstallationAttempts = 3;

// The domain for errors generated here.
static NSString * const SQRLShipItErrorDomain = @"SQRLShipItErrorDomain";

static RACSignal *watch(NSString *jobLabel) {
	SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:jobLabel];
	RACSignal *stateLocation = directoryManager.shipItStateURL;

	return [[SQRLShipItState
		readUsingURL:stateLocation]
		flattenMap:^(SQRLShipItState *state) {
			if (state.bundleIdentifier == nil) return [RACSignal empty];

			SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithURL:state.targetBundleURL bundleIdentifier:state.bundleIdentifier];
			return [listener waitForTermination];
		}];
}

static RACSignal *install(NSString *jobLabel) {
	SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:jobLabel];
	RACSignal *stateLocation = directoryManager.shipItStateURL;

	return [[[SQRLShipItState
		readUsingURL:stateLocation]
		catch:^(NSError *error) {
			NSLog(@"Error reading saved installer state: %@", error);

			// Exit successfully so launchd doesn't restart us again.
			return [RACSignal empty];
		}]
		flattenMap:^(SQRLShipItState *state) {
			BOOL freshInstall = (state.installerState == SQRLInstallerStateNothingToDo);
			SQRLInstaller *installer = [[SQRLInstaller alloc] initWithDirectoryManager:directoryManager];

			NSUInteger attempt = (freshInstall ? 1 : state.installationStateAttempt + 1);
			RACSignal *action;

			if (attempt > SQRLShipItMaximumInstallationAttempts) {
				action = [[[installer.abortInstallationCommand
					execute:state]
					initially:^{
						NSLog(@"Too many attempts to install from state %i, aborting update", (int)state.installerState);
					}]
					catch:^(NSError *error) {
						NSLog(@"Error aborting installation: %@", error);

						// Exit successfully so launchd doesn't restart us again.
						return [RACSignal empty];
					}];
			} else {
				action = [[[[[state
					writeUsingURL:stateLocation]
					initially:^{
						if (freshInstall) {
							NSLog(@"Beginning installation");
							state.installerState = SQRLInstallerStateClearingQuarantine;
						} else {
							NSLog(@"Resuming installation from state %i", (int)state.installerState);
						}

						state.installationStateAttempt = attempt;
					}]
					then:^{
						return [installer.installUpdateCommand execute:state];
					}]
					doCompleted:^{
						NSLog(@"Installation completed successfully");
					}]
					sqrl_addTransactionWithName:NSLocalizedString(@"Updating", nil) description:NSLocalizedString(@"%@ is being updated, and interrupting the process could corrupt the application", nil), state.targetBundleURL.path];
			}

			return action;
		}];
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		atexit_b(^{
			NSLog(@"ShipIt quitting");
		});

		if (argc < 2) {
			NSLog(@"Missing launchd job label for ShipIt");
			return EXIT_FAILURE;
		}
		NSString *jobLabel = @(argv[1]);

		if (argc < 3) {
			NSLog(@"Missing command for ShipIt, supported commands are 'watch' and 'install'");
			return EXIT_FAILURE;
		}
		NSString *command = @(argv[2]);

		RACSignal * (*commandFunction)(NSString *) = NULL;
		if ([command isEqualToString:@"watch"]) {
			commandFunction = &watch;
		} else if ([command isEqualToString:@"install"]) {
			commandFunction = &install;
		} else {
			NSLog(@"Unrecognised command");
			exit(EXIT_FAILURE);
		}

		RACSignal *signal = commandFunction(jobLabel);
		[signal subscribeError:^(NSError *error) {
			NSLog(@"Installation error: %@", error);
			exit(EXIT_FAILURE);
		} completed:^{
			exit(EXIT_SUCCESS);
		}];

		dispatch_main();
	}

	return EXIT_SUCCESS;
}

