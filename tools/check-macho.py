#!/usr/bin/env python3
"""Confirm a Mach-O is the iOS binary we meant to ship.

    tools/check-macho.py packaging/payload/gh

Checks three things, and exits non-zero with the reason if any fails:

  1. LC_BUILD_VERSION platform is 2 (iOS). A build that silently picked up the
     macOS SDK -- the default if $CC is not tools/clangwrap.sh -- links cleanly,
     exits 0, and is rejected by dyld on device with nothing useful in the log.
  2. Every LC_LOAD_DYLIB names a library that exists on iOS. In particular
     CoreFoundation must be the iOS bundle path; the macOS spelling
     (.framework/Versions/A/CoreFoundation) is a directory iOS does not have.
  3. LC_CODE_SIGNATURE is present. iOS will not exec a Mach-O with no cdhash.

Deliberately pure stdlib rather than otool/codesign, because the useful place to
run it is the Linux runner that assembles the .deb, where neither exists and
where the binary has just crossed an artifact boundary.
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0x0C
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2

# Everything a Go ios/arm64 build can legitimately pull in. Kept as an explicit
# allow-list so a new dependency has to be vetted by a human once, rather than
# discovered by a user whose gh will not launch.
ALLOWED = {
    "/usr/lib/libSystem.B.dylib",
    "/usr/lib/libresolv.9.dylib",
    "/usr/lib/libc++.1.dylib",
    "/usr/lib/libicucore.A.dylib",
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
    "/System/Library/Frameworks/Security.framework/Security",
    "/System/Library/Frameworks/CoreServices.framework/CoreServices",
}


def main(path):
    with open(path, "rb") as f:
        data = f.read()

    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        die("not a 64-bit little-endian Mach-O (fat binaries are not expected here)")

    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    platform = None
    dylibs = []
    signed = False

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8:
            die("corrupt load command at offset %d" % off)
        if cmd == LC_BUILD_VERSION:
            platform = struct.unpack_from("<I", data, off + 8)[0]
        elif cmd == LC_LOAD_DYLIB:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            raw = data[off + name_off:off + cmdsize]
            dylibs.append(raw.split(b"\0", 1)[0].decode("utf-8", "replace"))
        elif cmd == LC_CODE_SIGNATURE:
            signed = True
        off += cmdsize

    problems = []
    if platform is None:
        problems.append("no LC_BUILD_VERSION at all")
    elif platform != PLATFORM_IOS:
        problems.append(
            "LC_BUILD_VERSION platform is %d, expected %d (iOS).\n"
            "    The link used the wrong SDK -- CC must be tools/clangwrap.sh."
            % (platform, PLATFORM_IOS))

    for lib in dylibs:
        if lib not in ALLOWED:
            problems.append(
                "links %s, which is not known to exist on iOS.\n"
                "    Vet it, then add it to ALLOWED in this script." % lib)

    if not signed:
        problems.append(
            "no LC_CODE_SIGNATURE -- iOS refuses to exec code with no cdhash.\n"
            "    Sign it: ldid -Spackaging/payload/entitlements.plist <binary>")

    if problems:
        print("%s: NOT shippable" % path, file=sys.stderr)
        for p in problems:
            print("  !! %s" % p, file=sys.stderr)
        sys.exit(1)

    print("%s: iOS arm64, signed, %d dylib(s), all present on iOS"
          % (path, len(dylibs)))
    for lib in dylibs:
        print("    %s" % lib)


def die(msg):
    print("%s: %s" % (sys.argv[1], msg), file=sys.stderr)
    sys.exit(1)


if len(sys.argv) != 2:
    sys.exit("usage: check-macho.py <mach-o>")
main(sys.argv[1])
