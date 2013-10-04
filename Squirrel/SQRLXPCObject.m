//
//  SQRLXPCObject.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-09-29.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLXPCObject.h"
#import <ReactiveCocoa/EXTScope.h>

@implementation SQRLXPCObject

#pragma mark Lifecycle

- (id)initWithXPCObject:(xpc_object_t)object {
	if (object == NULL) return nil;

	self = [super init];
	if (self == nil) return nil;

	_object = xpc_retain(object);

	return self;
}

- (void)dealloc {
	xpc_release(_object);
}

#pragma mark NSObject

- (NSString *)description {
	char *xpcDescription = xpc_copy_description(self.object);

	@onExit {
		free(xpcDescription);
	};

	return [NSString stringWithFormat:@"<%@: %p>{ object = %s }", self.class, self, xpcDescription];
}

- (NSUInteger)hash {
	return xpc_hash(self.object);
}

- (BOOL)isEqual:(SQRLXPCObject *)obj {
	if (![obj isKindOfClass:SQRLXPCObject.class]) return NO;

	return xpc_equal(self.object, obj.object);
}

@end
