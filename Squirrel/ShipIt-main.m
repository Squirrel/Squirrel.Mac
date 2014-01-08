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
#import "ShipIt-Constants.h"

// The maximum number of times ShipIt should run the same installation state, in
// an attempt to update.
//
// If ShipIt is launched in the same state more than this number of times,
// updating will abort.
static const NSUInteger SQRLShipItMaximumInstallationAttempts = 3;

// The domain for errors generated here.
static NSString * const SQRLShipItErrorDomain = @"SQRLShipItErrorDomain";

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

static void installForState(SQRLDirectoryManager *directoryManager, RACSignal *state) {
	[[[state
		flattenMap:^(SQRLShipItState *state) {
			return [[waitForTerminationIfNecessary(state)
				ignoreValues]
				concat:[RACSignal return:state]];
		}]
		flattenMap:^(SQRLShipItState *state) {
			BOOL freshInstall = (state.installerState == SQRLInstallerStateNothingToDo);
			SQRLInstaller *installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:directoryManager.applicationIdentifier stateDefaultsKey:SQRLShipItStateDefaultsKey];

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
					writeToDefaultsDomain:directoryManager.applicationIdentifier key:SQRLShipItStateDefaultsKey]
					initially:^{
						if (freshInstall) {
							NSLog(@"Beginning installation");
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

			// Remove the saved state after successfull install or abort.
			action = [action
				doNext:^(id _) {
					CFPreferencesSetValue((__bridge CFStringRef)SQRLShipItStateDefaultsKey, NULL, (__bridge CFStringRef)directoryManager.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
					CFPreferencesSynchronize((__bridge CFStringRef)directoryManager.applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
				}];

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

		NSString *applicationIdentifier = directoryManager.applicationIdentifier;

		RACSignal *inProgressUpdateState = [SQRLShipItState
			readFromDefaultsDomain:applicationIdentifier key:SQRLShipItStateDefaultsKey];

		RACSignal *updateRequest = [[[SQRLShipItState
			readUsingURL:directoryManager.shipItStateURL]
			map:^(SQRLShipItState *state) {
				// Update requests from clients cannot select the state they
				// want to start from. Only preference read states can have a
				// non-initial installer state.
				SQRLShipItState *newState = [state copy];
				newState.installerState = SQRLInstaller.initialInstallerState;
				return newState;
			}]
			flattenMap:^(SQRLShipItState *state) {
				// Remove the update request from disk and duplicate to
				// preferences.
				return [[directoryManager.shipItStateURL
					tryMap:^(NSURL *location, NSError **errorRef) {
						return [NSFileManager.defaultManager removeItemAtURL:location error:errorRef] ? state : nil;
					}]
					doNext:^(SQRLShipItState *state) {
						[state writeToDefaultsDomain:applicationIdentifier key:SQRLShipItStateDefaultsKey];
					}];
			}];

		// Prefer to read from preferences, if no such state exists, read the
		// client request from disk into preferences.
		RACSignal *stateToStart = [inProgressUpdateState
			catch:^(NSError *error) {
				if (!([error.domain isEqualToString:SQRLShipItStateErrorDomain] && error.code == SQRLShipItStateErrorUnarchiving)) return [RACSignal error:error];
				return updateRequest;
			}];

		installForState(directoryManager, stateToStart);

		dispatch_main();
	}

	return EXIT_SUCCESS;
}

