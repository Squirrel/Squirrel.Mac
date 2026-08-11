// Build configuration for the Sparkle BinaryDelta sources Squirrel compiles
// out of the Sparkle submodule (Carthage/Checkouts/Sparkle). Sparkle sets these
// from its xcconfigs; Squirrel force-includes this header instead.

// Only Sparkle's own container format (delta major versions 3 and 4) is read;
// the XAR-based formats 1 and 2 are not built.
#define SPARKLE_BUILD_LEGACY_DELTA_SUPPORT 0
// LZMA/LZFSE/LZ4/ZLIB via libcompression only.
#define SPARKLE_BUILD_BZIP2_DELTA_SUPPORT 0

// Sparkle marks these classes objc_direct as a size optimisation; direct
// methods are not visible across image boundaries, and the tests create
// deltas with Sparkle's generator linked against this framework's archive
// classes, so keep ordinary dispatch.
#define SPU_OBJC_DIRECT
#define SPU_OBJC_DIRECT_MEMBERS
