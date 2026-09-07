#!/bin/sh
# clang, pointed at the iPhoneOS SDK.
#
# Go's ios/arm64 port requires external (cgo) linking -- CGO_ENABLED=0 fails
# with "ios/arm64 requires external (cgo) linking". Go therefore hands the link
# step to $CC, and $CC decides what platform the Mach-O claims to be.
#
# With the default macOS clang you get LC_BUILD_VERSION platform 1 (macOS) even
# though GOOS=ios, and CoreFoundation linked by its macOS bundle path
# (.framework/Versions/A/CoreFoundation), which does not exist on iOS. Both are
# fatal on device and neither is obvious from the build output.
#
# With this wrapper you get platform 2 (iOS) and the iOS framework paths, which
# is the whole reason no Mach-O patcher is needed in this project.
set -e
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun --sdk iphoneos --find clang)
exec "$CLANG" -arch arm64 -isysroot "$SDK" -mios-version-min="${IOS_MIN:-15.0}" "$@"
