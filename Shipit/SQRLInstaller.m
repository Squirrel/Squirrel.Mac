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

@interface SQRLInstaller ()

@property (nonatomic, strong) NSURL *targetBundleURL;
@property (nonatomic, strong) NSURL *updateBundleURL;
@property (nonatomic, strong) NSURL *backupURL;

@end

@implementation SQRLInstaller

- (id)initWithTargetBundleURL:(NSURL *)targetBundleURL updateBundleURL:(NSURL *)updateBundleURL backupURL:(NSURL *)backupURL {
    NSParameterAssert(targetBundleURL != nil);
    NSParameterAssert(updateBundleURL != nil);
    NSParameterAssert(backupURL != nil);
    
    self = [super init];
    if (self == nil) return nil;
    
    _targetBundleURL = targetBundleURL;
    _updateBundleURL = updateBundleURL;
    _backupURL = backupURL;
    
    return self;
}

- (BOOL)installUpdateWithError:(NSError **)errorRef {
    // Verify the update bundle.
    
    NSError *verificationError = nil;
    if (![SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:self.updateBundleURL error:&verificationError]) {
        if (errorRef != NULL) {
            *errorRef = [NSError errorWithDomain:SQRLInstallerErrorDomain code:SQRLInstallerFailedErrorCode userInfo:@{
                NSUnderlyingErrorKey: verificationError,
            }];
        }
        return NO;
    }
    
    // Move the old bundle to a backup location
    
    NSBundle *targetBundle = [NSBundle bundleWithURL:self.targetBundleURL];
    NSString *bundleVersion = [targetBundle objectForInfoDictionaryKey:(id)kCFBundleVersionKey];
    NSString *bundleExtension = self.targetBundleURL.pathExtension;
    NSString *backupAppName = [NSString stringWithFormat:@"%@_%@.%@", self.targetBundleURL.URLByDeletingPathExtension.lastPathComponent, bundleVersion, bundleExtension];
        
    NSURL *backupBundleURL = [self.backupURL URLByAppendingPathComponent:backupAppName];
    
    [NSFileManager.defaultManager removeItemAtURL:backupBundleURL error:NULL];
    
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
    
    [NSFileManager.defaultManager removeItemAtURL:self.targetBundleURL error:NULL];
    
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

    if (![SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:self.targetBundleURL error:&verificationError]) {
        // Move the backup version back into place
        
        [NSFileManager.defaultManager removeItemAtURL:self.targetBundleURL error:NULL];
        
        [self installItemAtURL:self.targetBundleURL fromURL:backupBundleURL error:NULL];
        
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
    if (![NSFileManager.defaultManager moveItemAtURL:sourceURL toURL:targetURL error:NULL]) {
        // Try a copy instead.
        return [NSFileManager.defaultManager copyItemAtURL:sourceURL toURL:targetURL error:errorRef];
    }
    NSLog(@"Copied bundle from %@ to %@", sourceURL, targetURL);
    return YES;
}

@end
