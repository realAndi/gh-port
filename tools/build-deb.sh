#!/usr/bin/env bash
# Assemble the .deb from a payload already built by tools/build-payload.sh.
#
#   tools/build-deb.sh [revision]
#
# The version comes from packaging/payload/PAYLOAD.version, which
# build-payload.sh writes, so the two cannot disagree about what was compiled.
#
# Split deliberately: build-payload.sh needs macOS (Xcode's iPhoneOS SDK, ldid),
# build-deb.sh needs dpkg-deb. In CI they are different runners and the binary
# moves between them as an artifact.
#
# Needs: dpkg-deb (brew install dpkg / apt install dpkg-dev), python3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$ROOT/packaging/payload"
OUT="${OUT:-$ROOT/repo/debs}"
GH_REPO="${GH_REPO:-}"
GH_PAGES="${GH_PAGES:-}"

# check-macho.py is shared with the other ports and lives in
# realAndi/ios-port-ci. CI checks that out and points CI_TOOLS at it; locally
# tools/ci.sh clones it on first use.
CI_TOOLS="${CI_TOOLS:-$("$ROOT/tools/ci.sh")}"

command -v dpkg-deb >/dev/null || { echo "need dpkg-deb (brew install dpkg)"; exit 1; }
[ -f "$PAYLOAD/gh" ] || {
    echo "missing packaging/payload/gh -- run tools/build-payload.sh on macOS first"; exit 1; }
[ -f "$PAYLOAD/gh.LICENSE" ] || {
    echo "missing packaging/payload/gh.LICENSE -- rebuild with tools/build-payload.sh"; exit 1; }
[ -f "$PAYLOAD/PAYLOAD.version" ] || {
    echo "missing packaging/payload/PAYLOAD.version -- rebuild with tools/build-payload.sh"; exit 1; }

read -r VERSION COMMIT DATE < "$PAYLOAD/PAYLOAD.version"
REVISION="${1:-$(cat "$ROOT/packaging/revision" 2>/dev/null || echo 1)}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

echo "==> gh $VERSION ($COMMIT, $DATE) revision $REVISION"

# The binary has usually crossed a runner boundary since it was built -- macOS
# compiles and signs it, Linux packs the .deb -- so re-check it here rather than
# trusting that the artifact arrived intact. Pure stdlib on purpose: otool and
# codesign do not exist on the Linux side, which is exactly where this matters.
echo "==> verifying the Mach-O"
python3 "$CI_TOOLS/check-macho.py" "$PAYLOAD/gh"

echo "==> staging"
STAGE="$TMP/stage"
LIB="$STAGE/var/jb/usr/local/lib/github-cli"
BIN="$STAGE/var/jb/usr/local/bin"
ZSHCOMP="$STAGE/var/jb/usr/share/zsh/site-functions"
BASHCOMP="$STAGE/var/jb/etc/bash_completion.d"
DOC="$STAGE/var/jb/usr/share/doc/com.andi.github-cli"
mkdir -p "$STAGE/DEBIAN" "$LIB" "$BIN" "$ZSHCOMP" "$BASHCOMP" "$DOC"

install -m 755 "$PAYLOAD/gh"                "$LIB/gh"
install -m 644 "$PAYLOAD/entitlements.plist" "$LIB/entitlements.plist"
install -m 755 "$PAYLOAD/gh-ios"            "$BIN/gh-ios"
install -m 644 "$PAYLOAD/completions/_gh"   "$ZSHCOMP/_gh"
install -m 644 "$PAYLOAD/completions/gh.bash" "$BASHCOMP/gh"

# We redistribute a compiled copy of somebody else's MIT-licensed source, so
# their notice ships with it. Ours is here too, since the packaging around it is
# separately licensed.
{
    printf 'GitHub CLI (upstream, %s)\nSource: https://github.com/cli/cli\n\n' "$VERSION"
    cat "$PAYLOAD/gh.LICENSE"
    printf '\n\n---\n\niOS packaging (this package)\nSource: https://github.com/%s\n\n' "${GH_REPO:-realAndi/gh-port}"
    cat "$ROOT/LICENSE"
} > "$DOC/copyright"
chmod 644 "$DOC/copyright"

BIN_SHA=$(sha256 "$PAYLOAD/gh")
sed -e "s|@GH_VERSION@|$VERSION|g" \
    -e "s|@GH_COMMIT@|$COMMIT|g" \
    -e "s|@GH_BINARY_SHA256@|$BIN_SHA|g" \
    "$PAYLOAD/version.env.in" > "$LIB/version.env"
chmod 644 "$LIB/version.env"

# Sileo shows this before downloading; a 38MB package that claims nothing looks
# broken. KB, as dpkg defines it.
ISIZE=$(du -sk "$STAGE" | cut -f1)

sed -e "s|@VERSION@|$VERSION-$REVISION|g" \
    -e "s|@ISIZE@|$ISIZE|g" \
    -e "s|@REPO@|$GH_REPO|g" -e "s|@PAGES@|$GH_PAGES|g" \
    "$ROOT/packaging/DEBIAN/control.in" > "$STAGE/DEBIAN/control"
[ -n "$GH_REPO"  ] || sed -i.bak '/^Icon:/d'      "$STAGE/DEBIAN/control"
[ -n "$GH_PAGES" ] || sed -i.bak '/^Depiction:/d' "$STAGE/DEBIAN/control"
rm -f "$STAGE/DEBIAN/control.bak"

install -m 755 "$ROOT/packaging/DEBIAN/postinst" "$STAGE/DEBIAN/postinst"
install -m 755 "$ROOT/packaging/DEBIAN/prerm"    "$STAGE/DEBIAN/prerm"

mkdir -p "$OUT"
DEB="$OUT/com.andi.github-cli_${VERSION}-${REVISION}_iphoneos-arm64.deb"
dpkg-deb -Zxz --root-owner-group --build "$STAGE" "$DEB" >/dev/null
echo "==> $DEB ($(du -h "$DEB" | cut -f1))"

# --- has the payload changed without the revision moving? -------------------
#
# The package version tracks upstream gh, so a change to the wrapper, the
# postinst or the entitlements does not move it. Republishing the same version
# with different content is invisible: apt sees a version it already has and
# offers nobody an upgrade, the fix reaches no device, and CI stays green.
#
# The published repo is the only honest answer to "what does this version
# currently mean", so compare against it rather than a local lockfile.
#
# gh itself is excluded from the comparison. Go builds are reproducible given
# the same toolchain, but the runner's Go and Xcode both move under us, so
# including it would fire this guard on every unrelated toolchain bump. The
# version it was built from IS compared, via version.env.
payload_digest() {
    local deb="$1" dir
    dir="$(mktemp -d)"
    ( cd "$dir" && ar x "$deb" \
      && mkdir -p x && tar xf data.tar.* -C x 2>/dev/null \
      && tar xf control.tar.* -C x 2>/dev/null )
    ( cd "$dir/x" && find . -type f \
        ! -name control ! -name md5sums ! -name gh -print0 | sort -z \
      | xargs -0 shasum -a 256 2>/dev/null ) | shasum -a 256 | cut -d' ' -f1
    rm -rf "$dir"
}

if [ -n "$GH_PAGES" ]; then
    PREV="$TMP/published.deb"
    if curl -fsSL "https://$GH_PAGES/debs/$(basename "$DEB")" -o "$PREV" 2>/dev/null; then
        if [ "$(payload_digest "$PREV")" != "$(payload_digest "$DEB")" ]; then
            echo
            echo "!! $VERSION-$REVISION is already published with different content."
            echo "   Republishing it would change nothing on anyone's device: apt sees"
            echo "   the same version and offers no upgrade."
            echo
            echo "   Bump packaging/revision (currently $REVISION) and rebuild."
            exit 1
        fi
        echo "    matches what is already published at this version"
    else
        echo "    not published yet at this version"
    fi
fi
