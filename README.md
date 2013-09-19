# Squirrel

Squirrel is an OS X app updater framework which moves the decision for which
version a client should be running out of the client and into the server.

Instead of publishing a feed of versions from which your app must select,
Squirrel updates to the version your server tells it to. This allows you to
intelligently update your clients based on the request you give to Squirrel.

Your request can include authentication details, custom headers or a request
body so that your server has the context it needs in order to supply the most
suitable update.

The update JSON Squirrel requests can be a static resource that you generate
each time you release a new version, or dynamically generated to point to any
release you want it to, based on criteria in the request.

Squirrel’s installer is designed to be fault tolerant and to ensure that the
updates it installs are valid.

# Adopting Squirrel

1. Add the Squirrel repository as a git submodule
1. Add a reference to Squirrel.xcodeproj to your project
1. Add Squirrel.framework as a target dependency
1. Link Squirrel.framework and add it to a Copy Files build phase which copies
it into your Frameworks directory
1. Ensure your Runpath Search Paths (`LD_RUNPATH_SEARCH_PATHS`) includes the
Frameworks directory Squirrel.framework is copied into

Once Squirrel is added to your project, you need to configure and start it.

```objc
#import <Squirrel/Squirrel.h>

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
	self.updater = [[SQRLUpdater alloc] initWithUpdateRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://mycompany.com/myapp/latest"]]];
	[self.updater startAutomaticChecksWithInterval:/* 4 Hours */ 60 * 60 * 4];
	[self.updater checkForUpdates];
}
```

Squirrel will periodically request and automatically download any updates.

Before your application terminates, it should tell Squirrel to install any
updates that it has downloaded:

```objc
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
	[self.updater installUpdateIfNeeded:^(BOOL success, NSError *error) {
		if (success) {
			NSLog(@"Successfully installed an update");
		} else {
			NSLog(@"Failed to update: %@", error);
		}

		[sender replyToApplicationShouldTerminate:YES];
	}];

	return NSTerminateLater;
}
```

# Update JSON Format

Squirrel requests the URL you provide with `Accept: application/json` and
expects the following schema in response:

```json
{
	"url": "http://mycompany.com/myapp/releases/myrelease",
	"name": "My Release Name",
	"notes": "Theses are some release notes innit",
	"pub_date": "2013-09-18T12:29:53+01:00",
}
```

The only required key is "url", the others are optional.

Squirrel will request "url" with `Accept: application/zip` and only supports
installing ZIP updates. If future update formats are supported their MIME type
will be added to the `Accept` header so that your server can return the
appropriate format.

"pub_date" if present must be formatted according to ISO 8601

# User Interface

Squirrel does not provide an updates interface, if you want to display available
updates, subscribe to the `SQRLUpdaterUpdateAvailableNotification` notification.

![:shipit:](http://shipitsquirrel.github.io/images/ship%20it%20squirrel.png)
