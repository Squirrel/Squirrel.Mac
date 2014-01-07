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

// Defaults key to store `SQRLShipItState` in while attempting a single install
// request.
static NSString * const SQRLShipItStateDefaultsKey = @"SQRLShipItStateDefaults";

// Waits for all instances of the target application (as described in the
// `state`) to exit, then sends completed.
static RACSignal *waitForTerminationIfNecessary(SQRLShipItState *state) {
	return [[RACSignal
		defer:^{
			if (state.bundleIdentifier == nil) return [RACSignal empty];

			SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithURL:state.targetBundleURL bundleIdentifier:state.bundleIdentifier];
			return [listener waitForTermination];
		}]
		setNameWithFormat:@"waitForTerminationIfNecessary"];
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

		const char *jobLabel = argv[1];
		SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:@(jobLabel)];
		RACSignal *stateLocation = directoryManager.shipItStateURL;



		[[[[[[SQRLShipItState
			readUsingURL:stateLocation]
			flattenMap:^(SQRLShipItState *state) {
				return waitForTerminationIfNecessary(state);
			}]
			then:^{
				// Read the latest state, in case it was modified by the
				// controlling application in the meantime.
				return [SQRLShipItState readUsingURL:stateLocation];
			}]
			catch:^(NSError *error) {
				NSLog(@"Error reading saved installer state: %@", error);

				// Exit successfully so launchd doesn't restart us again.
				return [RACSignal empty];
			}]
			flattenMap:^(SQRLShipItState *state) {
				NSString *applicationIdentifier = directoryManager.applicationIdentifier;
				NSString *stateDefaultsKey = SQRLShipItStateDefaultsKey;

				BOOL freshInstall = (state.installerState == SQRLInstallerStateNothingToDo);
				SQRLInstaller *installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:applicationIdentifier stateDefaultsKey:stateDefaultsKey];

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
						writeToDefaultsDomain:directoryManager.applicationIdentifier key:stateDefaultsKey]
						initially:^{
							if (freshInstall) {
								NSLog(@"Beginning installation");
								state.installerState = SQRLInstaller.initialInstallerState;
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

				if (state.relaunchAfterInstallation) {
					// Relaunch regardless of whether installation succeeds or
					// fails.
					action = [[action
						deliverOn:RACScheduler.mainThreadScheduler]
						finally:^{
							NSURL *bundleURL = state.targetBundleURL;
							if (bundleURL == nil) {
								NSLog(@"Missing target bundle URL, cannot relaunch application");
								return;
							}

							NSError *error = nil;
							if (![NSWorkspace.sharedWorkspace launchApplicationAtURL:bundleURL options:NSWorkspaceLaunchDefault configuration:nil error:&error]) {
								NSLog(@"Could not relaunch application at %@: %@", bundleURL, error);
								return;
							}

							NSLog(@"Application relaunched at %@", bundleURL);
						}];
				}

				return action;
			}]
			subscribeError:^(NSError *error) {
				NSLog(@"Installation error: %@", error);
				exit(EXIT_FAILURE);
			} completed:^{
				exit(EXIT_SUCCESS);
			}];

		dispatch_main();
	}

	return EXIT_SUCCESS;
}

