//
//  SQRLUpdateDelta.m
//  Squirrel
//

#import "SQRLUpdateDelta.h"
#import <ReactiveObjC/EXTKeyPathCoding.h>

@implementation SQRLUpdateDelta

#pragma mark Lifecycle

- (id)initWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
	self = [super initWithDictionary:dictionary error:error];
	if (self == nil) return nil;

	NSCharacterSet *notHex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet;
	NSString *missing = nil;
	if (self.fromVersion.length == 0) missing = @"from_version";
	else if (self.deltaURL.scheme == nil || self.deltaURL.path == nil) missing = @"url";
	else if (self.digest.length != 64 || [self.digest rangeOfCharacterFromSet:notHex].location != NSNotFound) missing = @"sha256";
	else if (![self.size isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)self.size) == CFBooleanGetTypeID() || CFNumberIsFloatType((__bridge CFNumberRef)self.size) || self.size.longLongValue <= 0) missing = @"size";

	if (missing != nil) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSKeyValueValidationError userInfo:@{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Validation failed", nil),
				NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"A delta update needs a valid \"%@\".", nil), missing],
			}];
		}
		return nil;
	}

	return self;
}

#pragma mark MTLJSONSerializing

+ (NSDictionary *)JSONKeyPathsByPropertyKey {
	return @{
		@keypath(SQRLUpdateDelta.new, fromVersion): @"from_version",
		@keypath(SQRLUpdateDelta.new, deltaURL): @"url",
		@keypath(SQRLUpdateDelta.new, digest): @"sha256",
		@keypath(SQRLUpdateDelta.new, size): @"size",
	};
}

+ (NSValueTransformer *)deltaURLJSONTransformer {
	return [NSValueTransformer valueTransformerForName:MTLURLValueTransformerName];
}

+ (NSValueTransformer *)digestJSONTransformer {
	return [MTLValueTransformer transformerUsingForwardBlock:^ id (NSString *digest, BOOL *success, NSError **error) {
		return [digest isKindOfClass:NSString.class] ? digest.lowercaseString : nil;
	}];
}

@end
