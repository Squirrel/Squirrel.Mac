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
#import "SQRLFileListener.h"

// The maximum number of times ShipIt should run the same installation state, in
// an attempt to update.
//
// If ShipIt is launched in the same state more than this number of times,
// updating will abort.
static const NSUInteger SQRLShipItMaximumInstallationAttempts = 3;

// The domain for errors generated here.
static NSString * const SQRLShipItErrorDomain = @"SQRLShipItErrorDomain";

static RACSignal *waitForReadyURL(NSURL *readyURL) {
	SQRLFileListener *listener = [[SQRLFileListener alloc] initWithFileURL:readyURL];
	return listener.waitUntilPresent;
}

static RACSignal *install(SQRLDirectoryManager *directoryManager, NSURL *requestURL) {
	return [[[SQRLShipItState
		readFromURL:requestURL]
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
					writeToURL:requestURL]
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

			if (state.relaunchAfterInstallation) {
				action = [action
					finally:^{
						FSRef target;
						if (!CFURLGetFSRef((__bridge CFURLRef)state.targetBundleURL, &target)) return;

						// LaunchServices is surprisingly root safe, see
						// Technical Note TN2083 - Process Manager and Launch
						// Services.
						LSApplicationParameters application = {
							.version = 0,
							.flags = kLSLaunchDefaults | kLSLaunchAndDisplayErrors,
							.application = &target,
						};
						LSOpenApplication(&application, NULL);
					}];
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
		SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:jobLabel];

		if (argc < 3) {
			NSLog(@"Missing ShipIt request URL");
			return EXIT_FAILURE;
		}
		NSURL *requestURL = [NSURL fileURLWithPath:@(argv[2])];

		if (argc < 4) {
			NSLog(@"Missing ShipIt ready URL");
			return EXIT_FAILURE;
		}
		NSURL *readyURL = [NSURL fileURLWithPath:@(argv[3])];

		[[[waitForReadyURL(readyURL)
			concat:install(directoryManager, requestURL)]
			doCompleted:^{
				[NSFileManager.defaultManager removeItemAtURL:readyURL error:NULL];
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

