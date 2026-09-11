// Quick and Nimble implement most of their Objective-C API in Swift. Xcode
// builds import it implicitly through the frameworks' Clang modules; this
// build has no modules, so every spec gets the generated headers up front.
#import <Nimble/Nimble-Swift.h>
#import <Quick/Quick-Swift.h>
