//
//  main.m
//  SquirrelApp
//
//  Created by Thomas Mönicke on 20/02/2017.
//  Copyright © 2017 Thomas. All rights reserved.
//

#import <Foundation/Foundation.h>

void ensureJSONFileExists(NSString *releaseFilePath)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if (![fileManager fileExistsAtPath:releaseFilePath]) {
        NSLog(@"creating file %@", releaseFilePath);

        BOOL success = [fileManager createDirectoryAtPath:[releaseFilePath stringByDeletingLastPathComponent] withIntermediateDirectories:true attributes:nil error:nil];

        if(!success) {
            NSLog(@"Could not create file path for release file %@", releaseFilePath);
        }

        success = [fileManager createFileAtPath:releaseFilePath
                                    contents:nil
                                    attributes:nil];
        if(!success) {
            NSLog(@"Could not create release file %@", releaseFilePath);
        }

        NSArray *array = [[NSArray alloc] init];

        //! @todo add notes conditionally
        NSDictionary *body = @{
                           @"releases": array,
                           @"currentRelease":@""
                           };

        NSData *releasesDATA = [[NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingPrettyPrinted error:NULL] copy];

        [releasesDATA writeToFile:releaseFilePath atomically:YES];
    } else {
        NSLog(@"Found %@", releaseFilePath);
    }

}

void ensureTextFileExists(NSString *releaseFilePath)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if (![fileManager fileExistsAtPath:releaseFilePath]) {
        NSLog(@"creating file %@", releaseFilePath);
        BOOL success = [fileManager createFileAtPath:releaseFilePath
                                            contents:nil
                                          attributes:nil];
        if(!success) {
            NSLog(@"Could not create release file %@", releaseFilePath);
        }
    }
}

void appendToSimpleFile(NSString *releaseFilePath, NSString* line)
{
    NSString *newLine = [NSString stringWithFormat:@"%@\n", line];

    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:releaseFilePath];
    [fileHandle seekToEndOfFile];
    [fileHandle writeData:[newLine dataUsingEncoding:NSUTF8StringEncoding]];
    [fileHandle closeFile];

    // version fileName timestamp

    NSLog(@"added line to %@", releaseFilePath);
}

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];

        //! figure out to just look if -releasify is set
        NSString *releasifyDmg = [standardDefaults stringForKey:@"releasify"];

        NSString *version = [standardDefaults stringForKey:@"version"];
        NSString *remotePath = [standardDefaults stringForKey:@"remote-path"];

        NSString *notes = @"";
        if([standardDefaults objectForKey:@"notes"]) {
            notes = [standardDefaults stringForKey:@"notes"];
        }

        NSString *releaseFilePath = [standardDefaults stringForKey:@"release-file"];
        BOOL forceOverwrite = [standardDefaults boolForKey:@"force-overwrite"];
        BOOL writeTextFile = false;
        if([standardDefaults objectForKey:@"simple-text"]) {
            writeTextFile = [standardDefaults boolForKey:@"simple-text"];
        }

        if(forceOverwrite) {
            NSLog(@"force overwrite set, an existing release with the same version will be overwritten!");
        }

        if(writeTextFile) {
            NSLog(@"Writing simple text file");
        }

        if(!releasifyDmg || !remotePath || !version || !releaseFilePath) {
            NSLog(@"please provide all arguments: [-releasify -version 1.0 -remote-path http://remote.path/ -notes \"new release\" -file abc.zip -release-file [-force-overwrite YES|NO] -simple-text YES|NO RELEASES.json]. Stop.");
            return 0;
        }

        //! get 'now'
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZZZ"];
        NSString *dateString = [formatter stringFromDate:[NSDate date]];

        if(writeTextFile) {
            NSString* unixTimeString = [NSString stringWithFormat:@"%d", (uint) [[NSDate date] timeIntervalSince1970]];
            ensureTextFileExists(@"RELEASES");
            NSString *newLine = [NSString stringWithFormat:@"%@ %@ %@", version, releasifyDmg, unixTimeString];

            appendToSimpleFile(@"RELEASES", newLine);
        } else {
            if(releasifyDmg && version && remotePath) {
                NSLog (@"releasify: %@\nversion: %@\nupdate", releasifyDmg, version);

                ensureJSONFileExists(releaseFilePath);

                //! -releasify foo.dmg -version 0.0.2 -update-from 0.0.1
                //! read file
                //! add entry $update-from : {..}
                NSError* cError = nil;
                NSString* releaseFileContent = [NSString stringWithContentsOfFile:releaseFilePath
                                                                         encoding:NSUTF8StringEncoding
                                                                            error:&cError];

                NSError *error = nil;
                NSData* releaseFileData = [releaseFileContent dataUsingEncoding:NSUTF8StringEncoding];

                if(releaseFileData) {

                    NSDictionary *releaseFileDict = [NSJSONSerialization
                                                     JSONObjectWithData:releaseFileData
                                                     options:0
                                                     error:&error];

                    if(error) {
                        NSLog(@"Error reading json data from %@:%@", releaseFilePath, error);
                    }

                    NSMutableArray* releases = releaseFileDict[@"releases"];
                    NSMutableArray *nreleases = [[NSMutableArray alloc] init];

                    for(id obj in releases) {
                        if([ obj[@"version"] isEqualToString:version ]) {
                            if(forceOverwrite) {
                                NSLog(@"Found %@ and force-overwrite is set, will replace it.", version);
                            } else {
                                NSLog(@"record %@ already exists, nothing to do.", version);
                                return 1;
                            }
                        } else {
                            [nreleases addObject:obj];
                        }
                    }

                    //! now write new record

                    //! @todo add notes conditionally
                    NSDictionary *newReleaseJSON = @{
                                                     @"version": version,
                                                     @"name": version,
                                                     @"notes": notes,
                                                     @"pub_date": dateString,
                                                     @"url": [NSString stringWithFormat:@"%@/%@", remotePath, releasifyDmg]
                                                     };

                    NSMutableDictionary *newRow = [[NSMutableDictionary alloc] init];
                    [newRow setObject:version forKey:@"version"];
                    [newRow setObject:newReleaseJSON forKey:@"updateTo"];

                    NSMutableArray* array = [[NSMutableArray alloc] init];

                    //! only if key does not exist
                    [array addObject:newRow];

                    //! copy old stuff over
                    for(id obj in nreleases) {
                        [array addObject:obj];
                    }

                    NSMutableDictionary* releasesJSON = [[NSMutableDictionary alloc] init];
                    [releasesJSON setValue:array forKey:@"releases"];
                    //! "currentRelease" points to latest record
                    [releasesJSON setValue:version forKey:@"currentRelease"];

                    NSData *releasesDATA = [[NSJSONSerialization dataWithJSONObject:releasesJSON options:NSJSONWritingPrettyPrinted error:NULL] copy];

                    [releasesDATA writeToFile:@"RELEASES.json" atomically:YES];
                    NSLog(@"new record written, %@", version);
                }

            } else {
                NSLog(@"smth is missing");
            }
        }
    }
    return 0;
}


//! show all update paths
//! check integrety
