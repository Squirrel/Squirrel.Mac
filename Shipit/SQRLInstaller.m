//
//  SQRLInstaller.m
//  Squirrel
//
//  Created by Alan Rogers on 30/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLInstaller.h"
#import "SQRLCodeSignatureVerification.h"

NSSTRING_CONST(SQRLInstallerErrorDomain);

const NSInteger SQRLInstallerFailedErrorCode = -1;

@interface SQRLInstaller () <NSFileManagerDelegate>

@property (nonatomic, strong) NSFileManager *fileManager;

@end

@implementation SQRLInstaller

- (id)initWithTargetBundleURL:(NSURL *)targetBundleURL updateBundleURL:(NSURL *)updateBundleURL backupURL:(NSURL *)backupURL {
    NSParameterAssert(targetBundleURL != nil);
    NSParameterAssert(updateBundleURL != nil);
    NSParameterAssert(backupURL != nil);
    
    self = [super init];
    
    _targetBundleURL = targetBundleURL;
    _updateBundleURL = updateBundleURL;
    _backupURL = backupURL;
    
    _fileManager = [[NSFileManager alloc] init];
    _fileManager.delegate = self;
    
    return self;
}

- (BOOL)installUpdateWithError:(NSError **)errorRef {
    // Verify the update bundle.
    
    NSError *verificationError = nil;
    if (![SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:[NSBundle bundleWithURL:self.updateBundleURL] error:&verificationError]) {
        if (errorRef != NULL) {
            *errorRef = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerFailedErrorCode userInfo:@{
                NSUnderlyingErrorKey: verificationError,
            }];
        }
        return NO;
    }
    
    // Move the old bundle to a backup location
    // TODO: find the version number or something.
    
    NSURL *backupBundleURL = [self.backupURL URLByAppendingPathComponent:@"GitHub_backup.app"];
    
    [self.fileManager removeItemAtURL:backupBundleURL error:NULL];
    
    NSError *backupError = nil;
    if (![self installItemAtURL:backupBundleURL fromURL:self.targetBundleURL error:&backupError]) {
        if (errorRef != NULL) {
            *errorRef = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerFailedErrorCode userInfo:@{
                NSUnderlyingErrorKey: backupError,
            }];
        }
        return NO;
    }
    
    // Move the new bundle into place.
    
    [self.fileManager removeItemAtURL:self.targetBundleURL error:NULL];
    
    NSError *installError = nil;
    if (![self installItemAtURL:self.targetBundleURL fromURL:self.updateBundleURL error:&installError]) {
        if (errorRef != NULL) {
            *errorRef = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerFailedErrorCode userInfo:@{
                NSUnderlyingErrorKey: installError,
            }];
        }
        return NO;
    }
    
    // Verify the bundle in place

    if (![SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:[NSBundle bundleWithURL:self.targetBundleURL] error:&verificationError]) {
        // Move the backup version back into place
        
        [self installItemAtURL:self.targetBundleURL fromURL:self.backupURL error:NULL];
        
        if (errorRef != NULL) {
            *errorRef = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerFailedErrorCode userInfo:@{
                NSUnderlyingErrorKey: verificationError,
            }];
        }
        return NO;
    }
    
    return YES;
}

- (BOOL)installItemAtURL:(NSURL *)targetURL fromURL:(NSURL *)sourceURL error:(NSError **)errorRef {
    NSParameterAssert(targetURL != nil);
    NSParameterAssert(sourceURL != nil);
    if (![self.fileManager moveItemAtURL:sourceURL toURL:targetURL error:NULL]) {
        // Try a copy instead.
        return [self.fileManager copyItemAtURL:sourceURL toURL:targetURL error:errorRef];
    }
    NSLog(@"Copied bundle from %@ to %@", sourceURL, targetURL);
    return YES;
}

#pragma mark NSFileManagerDelegate

- (BOOL)fileManager:(NSFileManager *)fileManager shouldProceedAfterError:(NSError *)error copyingItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath {
    if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileWriteFileExistsError) {
        return YES;
    }
    return NO;
}

@end
