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

# Building

Squirrel builds with [GN](https://gn.googlesource.com/gn/) and Ninja on top of
Chromium's `//build` configuration, the same way Electron builds it. A
standalone checkout fetches the build files, a pinned clang, GN, Ninja and the
third-party libraries with `gclient` from
[depot_tools](https://commondatastorage.googleapis.com/chrome-infra-docs/flat/depot_tools/docs/html/depot_tools_tutorial.html#_setting_up).
Xcode must be installed for the macOS SDK, `swiftc` and `xctest`.

```sh
git clone https://github.com/Squirrel/Squirrel.Mac.git
cd Squirrel.Mac
cp standalone.gclient .gclient
gclient sync

gn gen out/Default
ninja -C out/Default
script/test out/Default
```

`gclient sync` reads [`DEPS`](DEPS) and checks out `build/`, `buildtools/`,
`tools/clang/`, `third_party/llvm-build/`, `third_party/ninja/` and `vendor/`,
all of which git ignores.
The default Ninja target builds `Squirrel.framework` (with `ShipIt` in its
Resources), `ReactiveObjC.framework`, `Mantle.framework` and
`SquirrelTests.xctest`; `script/test` runs the tests with Xcode's `xctest`.
`gn gen out/Release --args='is_debug=false'` configures an optimized build;
`target_cpu` (`"arm64"` or `"x64"`) selects the architecture and
`mac_deployment_target` (11.0 by default, set in [`.gn`](.gn)) the minimum
macOS.

The targets an application needs are `//:squirrel_framework`,
`//:reactiveobjc_framework` and `//:mantle_framework` in [`BUILD.gn`](BUILD.gn).
That file only uses paths relative to itself and templates from `//build`, so a
project that already builds with Chromium's `//build` (as Electron does) can
check this repository out anywhere in its tree, check the libraries below out
under this repository's `vendor/` directory, and depend on those targets
directly.

# Adopting Squirrel

1. Build `Squirrel.framework`, `ReactiveObjC.framework` and `Mantle.framework`
   as above, or from your own GN build.
1. Link Squirrel.framework and copy all three frameworks into your
   application's Frameworks directory. Squirrel does not embed its
   [dependencies](#dependencies) itself.
1. Ensure your application's Runpath Search Paths (`LD_RUNPATH_SEARCH_PATHS`)
   includes the directory the three frameworks are copied into.

# Dependencies

Squirrel depends on [ReactiveObjC](https://github.com/ReactiveCocoa/ReactiveObjC)
and [Mantle](https://github.com/Mantle/Mantle), which `gclient sync` checks out
under `vendor/` at the revisions pinned in [`DEPS`](DEPS) and the build turns
into frameworks next to Squirrel's. If your application already uses either,
make sure it uses the same version as Squirrel.

Binary delta support compiles Sparkle's BinaryDelta sources and the bsdiff it
vendors straight out of a third checkout, `vendor/Sparkle`, pinned to a Sparkle
release tag (currently 2.9.5); nothing of Sparkle is linked as a framework and
applications need not ship it. To move the pin, change `sparkle_revision` in
`DEPS`, run `gclient sync`, build, run the tests, and commit; the files involved
are listed in [`filenames.gni`](filenames.gni).

The tests additionally use [Quick](https://github.com/Quick/Quick),
[Nimble](https://github.com/Quick/Nimble) and
[OHHTTPStubs](https://github.com/github/OHHTTPStubs), also pinned in `DEPS`
and built from source by [`SquirrelTests/BUILD.gn`](SquirrelTests/BUILD.gn).

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
	"pub_date": "2013-09-18T12:29:53+01:00",
	"sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
	"size": 104857600,
	"delta": {
		"from_version": "412",
		"url": "https://mycompany.example.com/myapp/releases/412-to-myrelease.delta",
		"sha256": "60303ae22b998861bce3b28f33eec1be758a213c86c93c076dbe9f558c11c752",
		"size": 7340032
	}
}
```

The only required key is "url", the others are optional.

Squirrel will request "url" with `Accept: application/zip` and only supports
installing ZIP updates. If future update formats are supported their MIME type
will be added to the `Accept` header so that your server can return the
appropriate format.

"pub_date" if present must be formatted according to ISO 8601.

"sha256" (64 hex digits) and "size" (a positive byte count), if present,
describe the ZIP at "url"; a download that does not match them is discarded
before it is opened and the check fails with
`SQRLUpdaterErrorInvalidUpdatePackage`. Values of any other type or shape are
logged and ignored rather than failing the check.

The ZIP is streamed to disk. If the transfer is interrupted (network loss,
sleep, the app quitting) and the server answered with an `ETag` or
`Last-Modified` and honours `Range`, the next check continues from where it
stopped instead of starting over; a resumed request the server refuses or
resets falls back to a full download. Progress is available on
`SQRLUpdater.downloadProgress`. Resuming after a relaunch relies on
`NSApplicationWillTerminateNotification`; a host that quits without posting it
(Electron does not) should call
`+[SQRLDownloader cancelAllWritingResumeDataWithTimeout:]` from its own quit
path. Downloads run in their own `NSURLSession`, so an `NSURLProtocol`
registered with `+registerClass:` sees the update check but not the download;
set `SQRLDownloader.sessionConfiguration` (with its `protocolClasses`) to
intercept both.

"delta", if present, offers a binary patch from one earlier build to this
release; it needs all four keys ("sha256" as 64 hex digits, "size" positive)
and is logged and ignored otherwise. When "from_version" equals the
running application's `CFBundleVersion`, Squirrel downloads the patch instead
of the ZIP, checks its "size" and "sha256", applies it to a copy of the running
application, and puts the result through the same code signing verification as
an unpacked ZIP. If any of that fails, or "from_version" is anything else, it
downloads the ZIP from "url" in the same check (its `downloadProgress` starting
again from zero), so a server can always include the one delta it has for the
version that asked. A delta that has been applied and staged is not fetched
again by later checks in the same process, and neither is one that downloaded
intact but would not apply or verify.

Patches are [Sparkle](https://sparkle-project.org) BinaryDelta files (format 3
or 4, any `--compression` except `bzip2`), made with Sparkle's
`BinaryDelta create <old.app> <new.app> <patch>`. A patch only applies to a
byte-identical copy of `<old.app>`, file modes included, and ShipIt clears the
group and other write bits of everything it installs; strip them from the app
before signing it (`chmod -R go-w MyApp.app`) so the shipped bundle, the
installed bundle and the trees the patch was made from all agree, otherwise
the patch applies once to a fresh install and never again. Files the patch adds
or rewrites are created with decomposed (NFD) names, so a non-ASCII file name
outside an archive such as `app.asar` can fail code signing verification and
cost a fallback to the ZIP. "from_version" may be a JSON string or number.

## Update File JSON Format

The alternate update technique uses a static JSON file, so you can host update
metadata on S3, a CDN, or any static file server — no dynamic backend required.

> **Electron users:** you must opt in to this mode with
> `autoUpdater.setFeedURL({ url: '…', serverType: 'json' })`. Without
> `serverType: 'json'`, Squirrel parses the response as the
> [server format](#update-server-json-format) above and you'll get
> `SQRLUpdaterErrorDomain code 6` ("invalid JSON response").

### How Squirrel decides to update

1. Fetch the file and read `currentRelease`.
2. Compare it to the running app's version
   (`CFBundleShortVersionString` — `app.getVersion()` in Electron) using a
   numeric string comparison.
3. If `currentRelease` is equal to or lower than the running version, do
   nothing.
4. Otherwise, look through `releases` for the entry whose `version` equals
   `currentRelease`, and use that entry's `updateTo` as the download payload
   (same shape as the [server format](#update-server-json-format)).

Only the entry matching `currentRelease` is ever used. Including older
releases is optional (useful if you also serve release notes from this
file); a single entry is fine.

### Minimal example

```json
{
  "currentRelease": "1.2.3",
  "releases": [
    {
      "version": "1.2.3",
      "updateTo": {
        "version": "1.2.3",
        "url": "https://mycompany.example.com/myapp/releases/MyApp-1.2.3.zip",
        "name": "1.2.3",
        "notes": "Bug fixes and performance improvements.",
        "pub_date": "2024-09-18T12:29:53+01:00"
      }
    }
  ]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `currentRelease` | ✅ | The latest available version. The only value compared against the running app. |
| `releases[].version` | ✅ | Lookup key. Squirrel uses the entry where this equals `currentRelease`. |
| `releases[].updateTo` | ✅ | The download payload for that version. Same shape as the [server format](#update-server-json-format). |
| `updateTo.url` | ✅ | Direct URL to the `.zip` for that version. |
| `updateTo.version` | — | Echoed into the `update-downloaded` event; conventionally the same as the outer `version`. |
| `updateTo.name` / `notes` / `pub_date` | — | Surfaced to your app for display. `pub_date` must be ISO 8601 if present. |
| `updateTo.sha256` / `size` | — | Digest (hex) and byte size of the `.zip`; a download that does not match is rejected. |
| `updateTo.delta` | — | Optional `{from_version, url, sha256, size}` binary patch from one earlier `CFBundleVersion`; tried first when it matches the running app, with the `.zip` as fallback. |

Point the updater directly at this file's URL — there's no required filename.

# User Interface

Squirrel does not provide any GUI components for presenting updates. If you want
to indicate updates to the user, make sure to [listen for downloaded
updates](#update-available-notifications).
