//
//  RACSignal+SQRLTransactionExtensions.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-07.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <ReactiveCocoa/ReactiveCocoa.h>

@interface RACSignal (SQRLTransactionExtensions)

// Begins a transaction before subscribing to the receiver, then automatically
// ends the transaction when the signal terminates.
//
// name        - A localized, user-friendly name for the work being done in this
//               transaction. This must not be nil.
// description - A localized, user-friendly description for the work being done
//               in this transaction. This may be nil.
//
// Returns a signal which forwards all of the receiver's events.
- (RACSignal *)sqrl_addTransactionWithName:(NSString *)name description:(NSString *)description;

// Begins a transaction before subscribing to the receiver, then automatically
// ends the transaction after subscribing.
//
// name        - A localized, user-friendly name for the work being done in this
//               transaction. This must not be nil.
// description - A localized, user-friendly description for the work being done
//               in this transaction. This may be nil.
//
// Returns a signal which forwards all of the receiver's events.
- (RACSignal *)sqrl_addSubscriptionTransactionWithName:(NSString *)name description:(NSString *)description;

@end
