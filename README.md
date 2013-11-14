# Squirrel

Squirrel is an OS X framework focused on making application updates **as safe
and transparent as updates to a website**.

Instead of publishing a feed of versions from which your app must select,
Squirrel updates to the version your server tells it to. This allows you to
intelligently update your clients based on the request you give to Squirrel.

Your request can include authentication details, custom headers or a request
body so that your server has the context it needs in order to supply the most
suitable update.

The update JSON Squirrel requests should be dynamically generated based on
criteria in the request, and whether an update is required. Squirrel relies
on server side support for determining whether an update is required, see [Server
Support](#server-support) below.

Squirrel’s installer is also designed to be fault tolerant, and ensure that any
updates installed are valid.

![:shipit:](http://shipitsquirrel.github.io/images/ship%20it%20squirrel.png)

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

	// Check for updates every 4 hours.
	[self.updater startAutomaticChecksWithInterval:60 * 60 * 4];
}
```

Squirrel will periodically request and automatically download any updates. When
your application terminates, any downloaded update will be automatically
installed.

## Update Notifications

To know when an update is ready to be installed, you can subscribe to the
`updates` signal on `SQRLUpdater`:

```objc
[self.updater.updates subscribeNext:^(SQRLDownloadedUpdate *downloadedUpdate) {
    NSLog(@"An update is ready to install: %@", downloadedUpdate);
}];
```

If you've been notified of an available update, and don't want to wait for it to
be installed automatically, you can terminate the app to begin the installation
process immediately.

If you want to install a downloaded update and automatically relaunch afterward,
`SQRLUpdater` can do that:

```objc
[[self.updater relaunchToInstallUpdate] subscribeError:^(NSError *error) {
    NSLog(@"Error preparing update: %@", error);
}];
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

# Server Support

If an update is required your server should respond with a status code of
[200 OK](http://tools.ietf.org/html/rfc2616#section-10.2.1) and include the
update JSON in the body. Squirrel **will** download and install this update,
even if the version of the update is the same as the currently running version.
To save redundantly downloading the same version multiple times your server must
inform the client not to update.

If no update is required your server must respond with a status code of
[204 No Content](http://tools.ietf.org/html/rfc2616#section-10.2.5). Squirrel
will check for an update again at the interval you specify.

# User Interface

Squirrel does not provide any GUI components for presenting updates. If you want
to indicate updates to the user, make sure to [listen for downloaded
updates](#update-notifications).
