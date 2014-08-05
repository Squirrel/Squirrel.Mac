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
#import "SQRLInstaller+Private.h"
#import "SQRLShipItRequest.h"

// The maximum number of times ShipIt should run the same installation state, in
// an attempt to update.
//
// If ShipIt is launched in the same state more than this number of times,
// updating will abort.
static const NSUInteger SQRLShipItMaximumInstallationAttempts = 3;

// The domain for errors generated here.
static NSString * const SQRLShipItErrorDomain = @"SQRLShipItErrorDomain";

static NSUInteger installationAttempts(NSString *applicationIdentifier) {
	return CFPreferencesGetAppIntegerValue((__bridge CFStringRef)SQRLShipItInstallationAttemptsKey, (__bridge CFStringRef)applicationIdentifier, NULL);
}

static BOOL setInstallationAttempts(NSString *applicationIdentifier, NSUInteger attempts) {
	CFPreferencesSetValue((__bridge CFStringRef)SQRLShipItInstallationAttemptsKey, (__bridge CFPropertyListRef)@(attempts), (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
	return CFPreferencesSynchronize((__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
}

static BOOL clearInstallationAttempts(NSString *applicationIdentifier) {
	CFPreferencesSetValue((__bridge CFStringRef)SQRLShipItInstallationAttemptsKey, NULL, (__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
	return CFPreferencesSynchronize((__bridge CFStringRef)applicationIdentifier, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
}

static RACSignal *install(SQRLDirectoryManager *directoryManager, NSURL *requestURL) {
	return [[SQRLShipItRequest
		readFromURL:requestURL]
		flattenMap:^(SQRLShipItRequest *request) {
			NSString *applicationIdentifier = directoryManager.applicationIdentifier;
			SQRLInstaller *installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:applicationIdentifier];

			NSUInteger attempt = installationAttempts(applicationIdentifier) + 1;
			setInstallationAttempts(applicationIdentifier, attempt);

			RACSignal *action;
			if (attempt > SQRLShipItMaximumInstallationAttempts) {
				action = [[[installer.abortInstallationCommand
					execute:request]
					initially:^{
						NSLog(@"Too many attempts to install, aborting update");
					}]
					catch:^(NSError *error) {
						NSLog(@"Error aborting installation: %@", error);

						// Exit successfully so launchd doesn't restart us
						// again.
						return [RACSignal empty];
					}];
			} else {
				action = [[[[installer.installUpdateCommand
					execute:request]
					initially:^{
						BOOL freshInstall = (attempt == 1);
						if (freshInstall) {
							NSLog(@"Beginning installation");
						} else {
							NSLog(@"Resuming installation attempt %i", (int)attempt);
						}
					}]
					doCompleted:^{
						NSLog(@"Installation completed successfully");
					}]
					sqrl_addTransactionWithName:NSLocalizedString(@"Updating", nil) description:NSLocalizedString(@"%@ is being updated, and interrupting the process could corrupt the application", nil), request.targetBundleURL.path];
			}

			// Clear the installation attempts for a successful abort or
			// install.
			action = [action doCompleted:^{
				clearInstallationAttempts(applicationIdentifier);
			}];

			if (request.launchAfterInstallation) {
				// Launch regardless of whether installation succeeds or fails.
				action = [[action
					deliverOn:RACScheduler.mainThreadScheduler]
					finally:^{
						NSURL *bundleURL = request.targetBundleURL;
						if (bundleURL == nil) {
							NSLog(@"Missing target bundle URL, cannot launch application");
							return;
						}

						NSError *error;
						if (![NSWorkspace.sharedWorkspace launchApplicationAtURL:bundleURL options:NSWorkspaceLaunchDefault configuration:nil error:&error]) {
							NSLog(@"Could not launch application at %@: %@", bundleURL, error);
							return;
						}

						NSLog(@"Application launched at %@", bundleURL);
					}];
			}

			return action;
		}];
}

// Waits for the termination file at the path provided, then reads the
// `SQRLShipItRequest` at the path provided and performs the install if the
// update passes validation.
//
// Arguments are expected in the following order:
//
// jobLabel   - The launchd job label for this task.
// requestURL - Location of the serialized `SQRLShipItRequest` file.
int main(int argc, const char * argv[]) {
	@autoreleasepool {
		atexit_b(^{
			NSLog(@"ShipIt quitting");
		});

		if (argc < 2) {
			NSLog(@"Missing launchd job label for ShipIt");
			return EXIT_FAILURE;
		}

		char const *jobLabel = argv[1];
		SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:@(jobLabel)];

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

		[[install(directoryManager, requestURL)
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
