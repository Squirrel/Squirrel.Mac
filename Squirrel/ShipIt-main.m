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

#include <spawn.h>
#include <sys/wait.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>

#import "NSError+SQRLVerbosityExtensions.h"
#import "RACSignal+SQRLTransactionExtensions.h"
#import "SQRLInstaller.h"
#import "SQRLInstaller+Private.h"
#import "SQRLTerminationListener.h"
#import "SQRLShipItRequest.h"

extern char **environ;

int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t attrs, int disclaim)
__attribute__((availability(macos,introduced=10.14),weak_import));

#define CHECK_ERR(expr) \
	{ \
		int err = (expr); \
    if (err) { \
        fprintf(stderr, "%s: %s", #expr, strerror(err)); \
        exit(err); \
    } \
	}

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

// Drain the Mach service port registered via MachServices in the launchd
// job dictionary before exit(0) so launchd sees no outstanding demand and
// does not immediately respawn the job. bootstrap_check_in transfers the
// receive right into this task, but that alone is not sufficient: launchd
// tracks demand independently of the port's lifetime, so the queued
// trigger message must be explicitly dequeued. On failure exits the
// message is intentionally left queued so the KeepAlive respawn is
// demand-backed while the launchd domain is in on-demand-only mode.
static void drainMachServicePort(const char *serviceName) {
	mach_port_t port = MACH_PORT_NULL;
	if (bootstrap_check_in(bootstrap_port, serviceName, &port) != KERN_SUCCESS) return;

	struct {
		mach_msg_header_t header;
		uint8_t body[4096];
	} msg;
	while (mach_msg(&msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
	                0, sizeof(msg), port, 0, MACH_PORT_NULL) == KERN_SUCCESS) {
		mach_msg_destroy(&msg.header);
	}
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

							posix_spawnattr_t attr;
							CHECK_ERR(posix_spawnattr_init(&attr));

							// Disclaim TCC responsibilities
							if (responsibility_spawnattrs_setdisclaim)
									CHECK_ERR(responsibility_spawnattrs_setdisclaim(&attr, 1));

							pid_t pid = 0;

							const char* launchPath = [exe fileSystemRepresentation];
							const char* signal = [launchSignal fileSystemRepresentation];
							const char* path = [bundleURL.path fileSystemRepresentation];
							const char* args[] = { launchPath, signal, path, 0 };
							int status = posix_spawn(&pid, [exe UTF8String], NULL, &attr, (char *const*)args, environ);
							if (status == 0) {
								NSLog(@"New ShipIt pid: %i", pid);
								do {
									if (waitpid(pid, &status, 0) != -1) {
										NSLog(@"ShipIt status %d", WEXITSTATUS(status));
									} else {
										perror("waitpid");
										exit(1);
									}
								} while (!WIFEXITED(status) && !WIFSIGNALED(status));
							} else {
								NSLog(@"posix_spawn: %s", strerror(status));
							}

							posix_spawnattr_destroy(&attr);

							NSLog(@"New ShipIt exited");
						} else {
							NSLog(@"Attempting to launch app on lower than 11.0");
// TODO: https://github.com/electron/electron/issues/43168
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
							if (![NSWorkspace.sharedWorkspace launchApplicationAtURL:bundleURL options:NSWorkspaceLaunchDefault configuration:@{} error:&error]) {
								NSLog(@"Could not launch application at %@: %@", bundleURL, error);
								return;
							}
#pragma clang diagnostic pop

							NSLog(@"Application launched at %@", bundleURL);
						}
					}];
			}

			return action;
		}]
		subscribeError:^(NSError *error) {
			if ([[error domain] isEqual:SQRLInstallerErrorDomain] && [error code] == SQRLInstallerErrorAppStillRunning) {
				NSLog(@"Installation cancelled: %@", error);
				clearInstallationAttempts(applicationIdentifier);
				drainMachServicePort(applicationIdentifier.UTF8String);
				exit(EXIT_SUCCESS);
			} else {
				NSLog(@"Installation error: %@", error);
				exit(EXIT_FAILURE);
			}
		} completed:^{
			drainMachServicePort(applicationIdentifier.UTF8String);
			exit(EXIT_SUCCESS);
		}];
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		atexit_b(^{
			NSLog(@"ShipIt quitting");
		});

		if (argc < 3) {
			NSLog(@"Missing launchd job label or state path for ShipIt (%d)", argc);
			if (argc >= 1) {
				NSLog(@"Arg 1: {%s}", argv[0]);
			}
			if (argc >= 2) {
				NSLog(@"Arg 2: {%s}", argv[1]);
			}
			return EXIT_FAILURE;
		}

		char const *jobLabel = argv[1];
		const char *statePath = argv[2];
		NSURL *shipItStateURL = [NSURL fileURLWithPath:@(statePath)];

		if (strcmp(jobLabel, [launchSignal UTF8String]) == 0) {
			NSLog(@"Detected this as a launch request");
// TODO: https://github.com/electron/electron/issues/43168
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			NSError *error;
			if (![NSWorkspace.sharedWorkspace launchApplicationAtURL:shipItStateURL options:NSWorkspaceLaunchDefault configuration:@{} error:&error]) {
				NSLog(@"Could not launch application at %@: %@", shipItStateURL, error);
			} else {
				NSLog(@"Successfully launched application at %@", shipItStateURL);
			}
#pragma clang diagnostic pop
			exit(EXIT_SUCCESS);
		} else {
			NSLog(@"Detected this as an install request");
			installRequest([SQRLShipItRequest readUsingURL:[RACSignal return:shipItStateURL]], @(jobLabel));
			dispatch_main();
		}
	}

	return EXIT_SUCCESS;
}
