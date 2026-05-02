//
//  main.m
//  shipit
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <ReactiveObjC/EXTScope.h>
#import <ReactiveObjC/RACCommand.h>
#import <ReactiveObjC/RACSignal+Operations.h>
#import <ReactiveObjC/RACScheduler.h>

#import "NSError+SQRLVerbosityExtensions.h"
#import "RACSignal+SQRLTransactionExtensions.h"
#import "SQRLInstaller.h"
#import "SQRLInstaller+Private.h"
#import "SQRLTerminationListener.h"
#import "SQRLShipItRequest.h"

// The maximum number of times ShipIt should run the same installation state, in
// an attempt to update.
//
// If ShipIt is launched in the same state more than this number of times,
// updating will abort.
static const NSUInteger SQRLShipItMaximumInstallationAttempts = 3;

static NSString * launchSignal = @"___launch___";

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

// Waits for all instances of the target application (as described in the
// `request`) to exit, then sends completed.
static RACSignal *waitForTerminationIfNecessary(SQRLShipItRequest *request) {
	return [[RACSignal
		defer:^{
			if (request.bundleIdentifier == nil) return [RACSignal empty];

			SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithURL:request.targetBundleURL bundleIdentifier:request.bundleIdentifier];
			return [listener waitForTermination];
		}]
		setNameWithFormat:@"waitForTerminationIfNecessary"];
}

static void installRequest(RACSignal *readRequestSignal, NSString *applicationIdentifier) {
	[[[[[readRequestSignal
		flattenMap:^(SQRLShipItRequest *request) {
			return waitForTerminationIfNecessary(request);
		}]
		ignoreValues]
		concat:readRequestSignal]
		flattenMap:^(SQRLShipItRequest *request) {
			SQRLInstaller *installer = [[SQRLInstaller alloc] initWithApplicationIdentifier:applicationIdentifier];

			NSUInteger attempt = installationAttempts(applicationIdentifier) + 1;
			setInstallationAttempts(applicationIdentifier, attempt);

			RACSignal *action;
			if (attempt > SQRLShipItMaximumInstallationAttempts) {
				action = [[[[installer.abortInstallationCommand
					execute:request]
					initially:^{
						NSLog(@"Too many attempts to install, aborting update");
					}]
					catch:^(NSError *error) {
						NSLog(@"Error aborting installation: %@", error);

						// Exit successfully so launchd doesn't restart us
						// again.
						return [RACSignal empty];
					}]
					concat:[RACSignal return:request]];
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
					doNext:^(SQRLShipItRequest *finalRequest) {
						NSLog(@"On main thread and launching: %@", finalRequest.targetBundleURL);
						NSURL *bundleURL = finalRequest.targetBundleURL;
						if (bundleURL == nil) {
							NSLog(@"Missing target bundle URL, cannot launch application");
							return;
						}

						NSLog(@"Bundle URL is valid");

						NSError *error;
						// Temporary workaround, on Big Sur and higher the executable
						// using NSWorkspace needs to actually exist on disk, at this point
						// this executable no longer exists on disk so we need to launch the
						// new one (which should be in the exact same spot) and ask for it
						// to launch the new app bundle URL
						if (@available(macOS 11.0, *)) {
							NSLog(@"Attempting to launch app on 11.0 or higher");

							NSString *exe = NSProcessInfo.processInfo.arguments[0];
							NSLog(@"Launching new ShipIt at %@ with instructions to launch %@", exe, bundleURL);

							NSTask *task = [[NSTask alloc] init];
							[task setLaunchPath: exe];
							[task setArguments: @[launchSignal, bundleURL.path]];
							[task launch];
							[task waitUntilExit];

							NSLog(@"New ShipIt exited");
						} else {
							NSLog(@"Attempting to launch app on lower than 11.0");
							if (![NSWorkspace.sharedWorkspace launchApplicationAtURL:bundleURL options:NSWorkspaceLaunchDefault configuration:@{} error:&error]) {
								NSLog(@"Could not launch application at %@: %@", bundleURL, error);
								return;
							}

							NSLog(@"Application launched at %@", bundleURL);
						}
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

		if (argc < 3) {
			NSLog(@"Missing launchd job label or state path for ShipIt");
			return EXIT_FAILURE;
		}

		char const *jobLabel = argv[1];
		const char *statePath = argv[2];
		NSURL *shipItStateURL = [NSURL fileURLWithPath:@(statePath)];

		if (strcmp(jobLabel, [launchSignal UTF8String]) == 0) {
			NSLog(@"Detected this as a launch request");
			NSError *error;
			if (![NSWorkspace.sharedWorkspace launchApplicationAtURL:shipItStateURL options:NSWorkspaceLaunchDefault configuration:@{} error:&error]) {
				NSLog(@"Could not launch application at %@: %@", shipItStateURL, error);
			} else {
				NSLog(@"Successfully launched application at %@", shipItStateURL);
			}
			exit(EXIT_SUCCESS);
		} else {
			NSLog(@"Detected this as an install request");
			installRequest([SQRLShipItRequest readUsingURL:[RACSignal return:shipItStateURL]], @(jobLabel));
			dispatch_main();
		}
	}

	return EXIT_SUCCESS;
}
