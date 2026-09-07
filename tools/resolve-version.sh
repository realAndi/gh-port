#!/usr/bin/env bash
# Which upstream gh tag should we build?
#
#   tools/resolve-version.sh            the latest cli/cli release
#   tools/resolve-version.sh v2.100.0   that tag, validated
#
# Echoes the tag on stdout and NOTHING else -- CI captures it. Progress and
# errors go to stderr.
#
# Runs on Linux, before the macOS job exists. See CONTRACT.md in ios-port-ci.
set -euo pipefail

UPSTREAM="https://github.com/cli/cli.git"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
              | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
    echo "==> latest upstream release is $VERSION" >&2
fi
case "$VERSION" in v*) ;; *) VERSION="v$VERSION" ;; esac

# A tag that does not exist would otherwise fail four minutes later, inside the
# macOS job, after paying for a checkout and a Go install.
git ls-remote --exit-code --tags "$UPSTREAM" "refs/tags/$VERSION" >/dev/null \
    || { echo "cli/cli has no tag $VERSION" >&2; exit 1; }

echo "$VERSION"
