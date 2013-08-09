//
//  main.m
//  TestApplication
//
//  Created by Justin Spahr-Summers on 2013-08-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Cocoa/Cocoa.h>

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		NSString *folder = [NSBundle bundleWithIdentifier:@"com.github.Squirrel.TestApplication"].bundlePath.stringByDeletingLastPathComponent;
		NSString *logPath = [folder stringByAppendingPathComponent:@"TestApplication.log"];
		NSLog(@"Redirecting logging to %@", logPath);

		freopen(logPath.fileSystemRepresentation, "a+", stderr);
		fprintf(stderr, "foobar\n");

		return NSApplicationMain(argc, argv);
	}
}
