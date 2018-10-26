# Squirrel

Squirrel is an OS X framework focused on making application updates **as safe
and transparent as updates to a website**.

Instead of publishing a feed of versions from which your app must select,
Squirrel updates to the version your server tells it to. This allows you to
intelligently update your clients based on the request you give to Squirrel.
The server can remotely drive behaviors like rolling back or phased rollouts.

Your request can include authentication details, custom headers or a request
body so that your server has the context it needs in order to supply the most
suitable update.

The update JSON Squirrel requests should be dynamically generated based on
criteria in the request, and whether an update is required. Squirrel relies
on server side support for determining whether an update is required, see
[Server Support](#server-support).

Squirrel's installer is also designed to be fault tolerant, and ensure that any
updates installed are valid.

![:shipit:](http://shipitsquirrel.github.io/images/ship%20it%20squirrel.png)

# Adopting Squirrel

1. Install xctool with `brew install xctool`
1. Add the Squirrel repository as a git submodule
1. Run `script/bootstrap` from within the submodule
1. Add references to Squirrel.xcodeproj and its [dependencies](#dependencies) to
   your project
1. Add Squirrel.framework as a target dependency
1. Link Squirrel.framework and add it to a Copy Files build phase which copies
it into your Frameworks directory
1. Ensure your application includes the [dependencies](#dependencies). Squirrel
does not embed them itself.

If you’re developing Squirrel on its own, then use `Squirrel.xcworkspace`.

# Dependencies

Squirrel depends on [ReactiveCocoa](http://github.com/ReactiveCocoa/ReactiveCocoa)
and [Mantle](https://github.com/Mantle/Mantle).

If your application is already using ReactiveCocoa, ensure it is using the same
version as Squirrel.

Otherwise, add a target dependency and Copy Files build phase entry for the
ReactiveCocoa.framework target included in Squirrel's repository, in
`Carthage/Checkouts/ReactiveCocoa`.

Similarly, ensure your application includes Mantle, or copies in the Squirrel
version.

Finally, ensure your application's Runpath Search Paths (`LD_RUNPATH_SEARCH_PATHS`)
includes the directory that Squirrel.framework, ReactiveCocoa.framework
and Mantle.framework are copied into.

# Configuration

Once Squirrel is added to your project, you need to configure and start it.

```objc
#import <Squirrel/Squirrel.h>

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
	NSURLComponents *components = [[NSURLComponents alloc] init];

	components.scheme = @"https";
	components.host = @"mycompany.com";
	components.path = @"/myapp/latest";

	NSString *bundleVersion = NSBundle.mainBundle.sqrl_bundleVersion;
	components.query = [[NSString stringWithFormat:@"version=%@", bundleVersion] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]

	self.updater = [[SQRLUpdater alloc] initWithUpdateRequest:[NSURLRequest requestWithURL:components.URL]];

	// Check for updates every 4 hours.
	[self.updater startAutomaticChecksWithInterval:60 * 60 * 4];
}
```

Squirrel will periodically request and automatically download any updates. When
your application terminates, any downloaded update will be automatically
installed.

## Update Requests

Squirrel is indifferent to the request the client application provides for
update checking. `Accept: application/json` is added to the request headers
because Squirrel is responsible for parsing the response.

For the requirements imposed on the responses and the body format of an update
response see [Server Support](#server-support).

Your update request must *at least* include a version identifier so that the
server can determine whether an update for this specific version is required. It
may also include other identifying criteria such as operating system version or
username, to allow the server to deliver as fine grained an update as you
would like.

How you include the version identifier or other criteria is specific to the
server that you are requesting updates from. A common approach is to use query
parameters, [Configuration](#configuration) shows an example of this.

## Update Available Notifications

To know when an update is ready to be installed, you can subscribe to the
`updates` signal on `SQRLUpdater`:

```objc
[self.updater.updates subscribeNext:^(SQRLDownloadedUpdate *downloadedUpdate) {
    NSLog(@"An update is ready to install: %@", downloadedUpdate);
}];
```

## Installing Updates

While downloaded updates are automatically installed when your application
terminates, if don't want to wait you can manually terminate the app to begin
the installation process immediately.

Once an [update available notification](#update-available-notifications) has
been received, you may want to present an interface informing the user about
the update and offering the ability to install and relaunch.

To explicitly install a downloaded update and automatically relaunch afterward,
subscribe to the `relaunchToInstallUpdate` signal on `SQRLUpdater`:

```objc
[[self.updater relaunchToInstallUpdate] subscribeError:^(NSError *error) {
    NSLog(@"Error preparing update: %@", error);
}];
```

# Server Support

Your server should determine whether an update is required based on the
[Update Request](#update-requests) your client issues.

If an update is required your server should respond with a status code of
[200 OK](http://tools.ietf.org/html/rfc2616#section-10.2.1) and include the
[update JSON](#update-server-json-format) in the body. Squirrel **will** download and
install this update, even if the version of the update is the same as the
currently running version. To save redundantly downloading the same version
multiple times your server must not inform the client to update.

If no update is required your server must respond with a status code of
[204 No Content](http://tools.ietf.org/html/rfc2616#section-10.2.5). Squirrel
will check for an update again at the interval you specify.

## Update Server JSON Format

When an update is available, Squirrel expects the following schema in response
to the update request provided:

```json
{
	"url": "https://mycompany.example.com/myapp/releases/myrelease",
	"name": "My Release Name",
	"notes": "Theses are some release notes innit",
	"pub_date": "2013-09-18T12:29:53+01:00"
}
```

The only required key is "url", the others are optional.

Squirrel will request "url" with `Accept: application/zip` and only supports
installing ZIP updates. If future update formats are supported their MIME type
will be added to the `Accept` header so that your server can return the
appropriate format.

"pub_date" if present must be formatted according to ISO 8601.

## Update File JSON Format

The alternate update technique uses a plain JSON file meaning you can store your
update metadata on S3 or another static file store. The format of this file is
detailed below:

```json
{
	"currentRelease": "1.2.3",
	"releases": [
		{
			"version": "1.2.1",
			"updateTo": {
				"version": "1.2.1",
				"pub_date": "2013-09-18T12:29:53+01:00",
				"notes": "Theses are some release notes innit",
				"name": "1.2.1",
				"url": "https://mycompany.example.com/myapp/releases/myrelease"
			}
		},
		{
			"version": "1.2.3",
			"updateTo": {
				"version": "1.2.3",
				"pub_date": "2014-09-18T12:29:53+01:00",
				"notes": "Theses are some more release notes innit",
				"name": "1.2.3",
				"url": "https://mycompany.example.com/myapp/releases/myrelease3"
			}
		}
	]
}
```

# User Interface

Squirrel does not provide any GUI components for presenting updates. If you want
to indicate updates to the user, make sure to [listen for downloaded
updates](#update-available-notifications).
