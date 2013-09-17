# Squirrel

Squirrel is an OS X app updater framework which moves the decision for which
version a client should be running out of the client and into the server.

Instead of publishing a feed of versions from which your App must select,
Squirrel updates to the version your server tells it to. This allows you to
intelligently update your clients based on the information in the Squirrel
request.

The JSON resource Squirrel requests can be a static resource that you generate
each time you release a new version, or dynamically generated to point to any
release you want it to, based on criteria in the request.

# Adopting Squirrel

1. Add the Squirrel repository as a git submodule
2. Add a reference to Squirrel.xcodeproj to your project
3. Add a Squirrel.framework as a target dependency
4. Link Squirrel.framework and add it to a Copy Files build phase which copies
it into your Frameworks directory
5. Ensure your Runpath Search Paths (`LD_RUNPATH_SEARCH_PATHS`) includes the
Frameworks directory Squirrel.framework is copied into

Once Squirrel is added to your project, you need to configure and start it.

```objc
#import <Squirrel/Squirrel.h>
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
	SQRLUpdater.sharedUpdater.APIEndpoint = [NSURL URLWithString:@"https://mycompany.com/myapp/latest"];
	[SQRLUpdater.sharedUpdater startAutomaticChecksWithInterval:/* 4 Hours */ 60*60*4];
	[SQRLUpdater.sharedUpdater checkForUpdates];
}
```

Squirrel will periodically request and automatically download any updates.

When your application terminates, it should tell Squirrel to install any updates
that it has downloaded:

```objc
- (void)applicationWillTerminate:(NSNotification *)notification {
	[SQRLUpdater.sharedUpdate installUpdateIfNeeded:^(BOOL success, NSError *error) {

	}];
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
}
```

The only required key is "url", the others are optional.

Squirrel will request "url" with `Accept: application/zip` and only supports
installing ZIP updates. If future update formats are supported their MIME type
will be added to the `Accept` header so that your server can return the
appropriate format.

# User Interface

Squirrel does not provide an updates interface, if you want to display available
updates, subscribe to the `SQRLUpdaterUpdateAvailableNotification` notification.

![:shipit:](http://shipitsquirrel.github.io/images/ship%20it%20squirrel.png)
