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
	self = [super init];
	if (self == nil) return nil;

	if (object != NULL) {
		_object = xpc_retain(object);
	}

	return self;
}

- (void)dealloc {
	if (_object != NULL) {
		xpc_release(_object);
		_object = NULL;
	}
}

#pragma mark NSObject

- (NSString *)description {
	char *xpcDescription = NULL;
	if (self.object != NULL) xpcDescription = xpc_copy_description(self.object);

	@onExit {
		free(xpcDescription);
	};

	return [NSString stringWithFormat:@"<%@: %p>{ object = %s }", self.class, self, xpcDescription];
}

- (NSUInteger)hash {
	return (self.object != NULL ? xpc_hash(self.object) : 0);
}

- (BOOL)isEqual:(SQRLXPCObject *)obj {
	if (![obj isKindOfClass:SQRLXPCObject.class]) return NO;

	if (self.object == obj.object) {
		return YES;
	} else if (self.object == NULL || obj.object == NULL) {
		return NO;
	} else {
		return xpc_equal(self.object, obj.object);
	}
}

@end
