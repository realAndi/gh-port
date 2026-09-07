# gh-port

GitHub's official CLI, `gh`, running natively on jailbroken iOS, distributed as
a Sileo/APT package.

This is the easy sibling of [CCForiOS](https://github.com/realAndi/CCForiOS).
That port needed a Mach-O patcher, a shim dylib, a JIT emulation layer and an
on-device build in `postinst`, because Claude Code is a proprietary Bun binary
that only ships for macOS. `gh` is Go, `ios/arm64` is a first-class Go port, and
`gh` is MIT licensed. The unmodified upstream source cross-compiles to a real
iOS executable in about 27 seconds, every symbol it imports exists on iOS, and
the executable ships inside the `.deb`. The whole port is a three-line clang
wrapper that points the linker at the right SDK, a shell wrapper whose one
load-bearing line is `export HOME`, and packaging.

| | |
|---|---|
| Sileo source | `https://reallyitsandi.com/repo/` |
| Package | `com.andi.github-cli` ("GitHub CLI (gh)") |
| Source | https://github.com/realAndi/gh-port |
| Upstream | https://github.com/cli/cli (MIT) |
| Current upstream | gh 2.100.0 (`45437bc7eeeb3359bbfddd1742f79de7652fd3e2`) |
| Verified on | iPhone 15 Pro (A17 Pro), iOS 17.3 (21D50), Dopamine rootless (`/var/jb`, Procursus) |
| Status | **installed, signed in and working** — see [Status](#status-what-is-verified-and-what-is-not) |

## Installing

Sileo → Sources → **+** → `https://reallyitsandi.com/repo/`, then install
**GitHub CLI (gh)**. Then sign in — once:

```sh
gh auth login
gh pr list
```

Requirements:

* a rootless jailbreak (`/var/jb`)
* iOS 15.0 or later. The package declares `firmware (>= 15.0)` and this is the
  binary's real floor, not a guess — see
  [Why iOS 15.0 is the floor](#why-ios-150-is-the-floor)
* `zsh`, `git`, `uikittools` — declared as dependencies, so Sileo offers to
  install anything missing. `gh` shells out to `git` for everything that
  touches a local repository, and `uikittools` provides `uiopen`, which is how
  `gh` opens Safari. `openssh` is recommended, for `git@github.com` remotes.
* 38 MB of disk. **No network connection during install**: unlike CCForiOS,
  the binary is in the package, so nothing is downloaded.

The download is 9.7 MB (9,724,028 bytes, xz-compressed). Install is as fast as
dpkg can unpack it: `postinst` checks the binary's hash, takes over the `gh`
name, and runs `gh --version` once to prove the thing executes.

Sileo and Zebra do not check repository signatures, so that is all they need.
The `apt` CLI does check. The repo is signed, so install the key once and name
it in the source line:

```sh
sudo mkdir -p /var/jb/usr/share/keyrings
curl -fsSL https://reallyitsandi.com/repo/andi.gpg \
  | sudo tee /var/jb/usr/share/keyrings/andi.gpg >/dev/null

echo 'deb [signed-by=/var/jb/usr/share/keyrings/andi.gpg] https://reallyitsandi.com/repo/ ./' \
  | sudo tee /var/jb/etc/apt/sources.list.d/andi.list
sudo apt update && sudo apt install com.andi.github-cli
```

The key goes in `usr/share/keyrings`, not `/var/jb/etc/apt/trusted.gpg.d/`: a
key in the global store can validate *any* repository apt sees, whereas
`signed-by=` limits it to this one.

Then run `gh`. `/var/jb/usr/local/bin` is on the PATH of a *login* shell, which
is what NewTerm gives you, but not of a non-interactive `ssh host 'cmd'`. Over
SSH use:

```sh
ssh phone 'zsh -l -c "gh --version"'
```

Zsh and bash completions are installed to `/var/jb/usr/share/zsh/site-functions/_gh`
and `/var/jb/etc/bash_completion.d/gh`.

## Signing in

```sh
gh auth login
```

Pick GitHub.com, a git protocol, and "Login with a web browser". `gh` prints a
one-time code, opens `https://github.com/login/device` in Safari, you type the
code in, and `gh` polls until GitHub issues the token. This is exactly the
desktop flow; nothing in it is iOS-specific.

It is worth being precise about which flow this is, because it matters for what
can go wrong on a phone. `gh auth login` calls `flow.DetectFlow()`
(`internal/authflow/flow.go:95`), and `cli/oauth`'s `DetectFlow` tries the
**device flow first** and only falls back to the web-application flow if the
OAuth app reports device flow unsupported (`cli/oauth` v1.2.2, `oauth.go:97-104`).
GitHub's "GitHub CLI" app supports device flow, so the default path needs
nothing from the device except an outbound HTTPS connection and a way to open a
URL. The web-application flow — a local HTTP server on a random port with the
`http://127.0.0.1/callback` redirect (`flow.go:108-109`) — is not exercised at
all on GitHub.com.

Opening the URL is also not load-bearing. `gh`'s `BrowseURL` swallows a browser
launch failure, prints the URL and `Please try entering the URL in your browser
manually`, and keeps polling (`flow.go:78-83`). So if `uiopen` is missing or
misbehaves, sign-in still completes; you just open the URL yourself.

The other two ways in work unchanged:

```sh
gh auth login --with-token < token.txt   # a PAT, no browser
GH_TOKEN=ghp_... gh api user             # environment only, nothing stored
```

**No build secrets are involved.** Upstream hardcodes the "GitHub CLI" OAuth
app — client ID `178c6fc778ccc68e1d6a` — in `internal/authflow/flow.go:20-25`,
with the comment "This value is safe to be embedded in version control".
`tools/build-gh.sh` deliberately does not inject `oauthClientID` or
`oauthClientSecret` via `-ldflags -X`, so a default build does a real
`gh auth login` against the same app the official builds use.

### Where the token goes

**The token is stored in plain text, in `~/.config/gh/hosts.yml`.** Anything
that can read that file can act as you on GitHub. This is not a bug in the port
and there is no entitlement or setting that changes it; here is the mechanism.

On desktop, `gh` stores tokens in the system keychain through
`zalando/go-keyring` v0.2.8. Its darwin backend does not call `SecItemAdd`; it
shells out to a CLI:

```go
// keyring_darwin.go:29
execPathKeychain = "/usr/bin/security"
```

iOS does not have `/usr/bin/security`. The `exec` fails immediately with
`ENOENT` — it does not sit in the 60 s timeout that `gh`'s
`internal/keyring/keyring.go` wraps around every keyring call. `gh` treats
that failure as ordinary:

* `AuthConfig.Login` (`internal/config/config.go:419`) tries
  `keyring.Set` (`config.go:424`), and when that returns an error writes the token as
  `oauth_token` under the user in `hosts.yml` instead (`config.go:431-434`),
  returning `insecureStorageUsed = true`. The login command then prints
  `! Authentication credentials saved in plain text`
  (`pkg/cmd/auth/shared/login_flow.go:208-209`).
* `AuthConfig.ActiveToken` (`config.go:257`) reads the environment and the
  config file *first* and consults the keyring only if those are empty, so
  once a plaintext token exists the missing keychain is never touched again.

This is the same code path `gh` takes on Linux with no secret service, and
upstream documents it as supported. `--insecure-storage` on `gh auth login`
makes the choice explicit rather than fallen-into, and the `postinst` says as
much on a fresh install. The `.deb` description and depiction say it too. It is
the one real behavioural difference from desktop `gh`, and the reason the
entitlements carry no keychain keys: no entitlement can conjure up a missing
CLI binary.

Contrast the same problem in CCForiOS, where the difference is not the phone
but the upstream:

| | Claude Code (CCForiOS) | gh |
|---|---|---|
| credential store | `Bun.secrets`, compiled into the binary | `/usr/bin/security` via go-keyring |
| on iOS | the write silently does nothing | the `exec` fails fast with `ENOENT` |
| upstream fallback | none — it reads the legacy file once, then deletes it | plaintext `oauth_token` in `hosts.yml`, by design |
| a sign-in survives | exactly one run | indefinitely |
| what the port had to do | a custom OAuth client and a wrapper that re-creates the credential file before every launch | nothing |

## How it works

### Go's ios/arm64 port

This is the entire build:

```sh
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC=tools/clangwrap.sh \
  go build -trimpath \
    -ldflags "-s -w -X github.com/cli/cli/v2/internal/build.Version=2.100.0 \
                    -X github.com/cli/cli/v2/internal/build.Date=2026-09-03" \
    ./cmd/gh
```

Unmodified upstream source, no fork, no patches, about 27 seconds on an Apple
Silicon Mac. Go has shipped `ios` as a `GOOS` since 1.16, and it is a proper
port, not an alias: `runtime.GOOS` reports `"ios"`, the `darwin` build tag is
also satisfied so all of the ecosystem's `*_darwin.go` files compile in, and the
runtime and standard library have `ios`-specific branches where the OS differs.
Three of those branches are what this README is mostly about — the home
directory, the resolver and the certificate verifier.

### The one trap: `$CC` decides what platform the binary is

`GOOS=ios` on its own is not enough, and the failure is silent.

Go's ios/arm64 port requires external linking. `CGO_ENABLED=0` fails outright
with `ios/arm64 requires external (cgo) linking`, so the final link is handed to
`$CC` — and it is `$CC`, not Go, that decides what platform the Mach-O claims
and which framework paths get written into it. Both outcomes were built and
inspected:

| `CC` | `LC_BUILD_VERSION` | CoreFoundation is linked as | on device |
|---|---|---|---|
| default `clang` (macOS SDK) | platform 1 (macOS) | `.../CoreFoundation.framework/Versions/A/CoreFoundation` | dyld rejects the platform; the path does not exist on iOS either |
| `tools/clangwrap.sh` | platform 2 (iOS), minos 15.0 | `.../CoreFoundation.framework/CoreFoundation` | loads |

The wrong build links cleanly and exits 0. Nothing in the `go build` output
distinguishes the two. `tools/clangwrap.sh` is the fix in its entirety:

```sh
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun --sdk iphoneos --find clang)
exec "$CLANG" -arch arm64 -isysroot "$SDK" -mios-version-min="${IOS_MIN:-15.0}" "$@"
```

For comparison: that `Versions/A/` path is exactly what CCForiOS's patcher has
to rewrite in 38 C strings inside the Claude Code binary, because Bun `dlopen`s
CoreFoundation by its macOS bundle path at runtime. Here the linker simply
writes the iOS path when pointed at the iOS SDK, and there is nothing to patch.

Because the failure is invisible at build time, `tools/check-macho.py` runs
after every build and again on the Linux runner that assembles the package.
It parses the load commands in pure Python and fails the build unless
`LC_BUILD_VERSION` is platform 2, every `LC_LOAD_DYLIB` is on an explicit
allow-list of libraries known to exist on iOS (with CoreFoundation at the iOS
path), and `LC_CODE_SIGNATURE` is present. It has been negative-tested: run
against a `GOOS=ios` binary linked with the macOS SDK it reports
`LC_BUILD_VERSION platform is 1, expected 2 (iOS)` and the
`.framework/Versions/A/` path, and exits 1.

### The resulting binary

A thin Mach-O 64-bit arm64 binary, `MH_EXECUTE`, PIE, 22 load commands,
`LC_BUILD_VERSION` platform 2 (iOS) minos 15.0 sdk 26.5, 38,941,424 bytes
after `-s -w`. It links exactly four dylibs, every one of which exists on iOS
at that path:

```
/usr/lib/libSystem.B.dylib
/usr/lib/libresolv.9.dylib
/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation
/System/Library/Frameworks/Security.framework/Security
```

It has 154 undefined symbols:

| family | count | what for |
|---|---|---|
| ordinary POSIX / libSystem | 126 | the Go runtime: `pthread_create`, `sigaction`, `mmap`, `kqueue`/`kevent`, `fork`/`execve`, … |
| `CF*` (CoreFoundation) | 18 | `crypto/x509`'s root-store access, plus three `CFBundle*` calls from the runtime (below) |
| `SecTrust*`, `SecCertificate*`, `SecPolicy*` | 7 | `crypto/x509` chain verification through Security.framework |
| `res_9_ninit`, `res_9_nsearch`, `res_9_nclose` | 3 | Go's darwin resolver: `net` uses libresolv rather than parsing `/etc/resolv.conf` |

**Nothing is missing, so there is no shim.** CCForiOS had to `dlsym` all 840 of
Claude Code's imports on the device and found four that iOS's libSystem does not
export, which is what its shim exists to supply. Here the link ran against the
iPhoneOS SDK's stubs, so all 154 symbols are by construction exported by iOS's
libraries. (Whether each one also exists on iOS *15* is a separate question the
linker does not ask — that is what the deployment floor is about.)

One of the CoreFoundation users deserves a note, because it is the runtime
assuming it lives in an app bundle. `runtime/cgo`'s iOS init
(`gcc_darwin_arm64.c`, `init_working_dir`) calls `CFBundleGetMainBundle()` and
looks for an `Info.plist` next to the executable; if it finds one it `chdir`s
into that directory. With no `Info.plist` it returns and the working directory
is left alone, which is what a CLI needs — `gh` detects the repository from
`cwd`. **Do not put an `Info.plist` in `/var/jb/usr/local/lib/github-cli/`.**
If CoreFoundation returns no main bundle at all for a bare executable, the
runtime prints `runtime/cgo: no main bundle` to stderr and continues; whether
that line appears on a real device is one of the things not yet observed.

### No JIT, at all

Go is ahead-of-time compiled. Nothing in the process ever writes to executable
memory. iOS's W^X enforcement, `MAP_JIT`, `pthread_jit_write_protect_np`, the
`mprotect` flip, the per-thread-versus-process-wide race and
`BUN_JSC_useConcurrentJIT=0` — the entire load-bearing middle of the CCForiOS
port — are simply not in the picture. There is no interpreter to fall back to
because there is nothing to interpret.

The entitlements follow from that. `packaging/payload/entitlements.plist`
carries three keys and explains in comments what it does not carry:

| key | why |
|---|---|
| `platform-application` | run as a platform binary rather than a sandboxed app |
| `com.apple.private.security.no-sandbox` | `gh` reads and writes repositories anywhere on the filesystem and forks `git` |
| `get-task-allow` | debuggable |

Absent on purpose: every JIT key (`dynamic-codesigning`,
`com.apple.security.cs.allow-jit`, `allow-unsigned-executable-memory`,
`skip-library-validation`), because Go does not need them; and both keychain
keys (`application-identifier`, `keychain-access-groups`), because the keyring
failure is a missing CLI, not a missing entitlement. If go-keyring ever grows a
direct `SecItem` backend the keychain keys go back — CCForiOS confirmed
`SecItemAdd` works on iOS with a keychain group named after the package.

### Why iOS 15.0 is the floor

Go's `crypto/x509` on darwin verifies certificate chains through
`SecTrustEvaluateWithError` and then reads the chain back with
`SecTrustCopyCertificateChain`. Both are among the seven `Sec*` imports above.
`SecTrustCopyCertificateChain` is iOS 15.0+.

`tools/build-gh.sh` pins `IOS_MIN=15.0` and the control file declares
`firmware (>= 15.0)` to match. Lowering the minimum produces a binary that
links just as cleanly and whose TLS cannot work on the devices the lower floor
admits — the linker does not check symbol availability against the deployment
target.

### Runtime environment

`/var/jb/usr/local/bin/gh-ios`, which `gh` symlinks to, sets three things and
`exec`s `/var/jb/usr/local/lib/github-cli/gh`:

| variable | why |
|---|---|
| `HOME` | **correctness, not convenience.** `os.UserHomeDir()` under `GOOS=ios` returns `"/"` when `$HOME` is unset (`src/os/file.go:620-621` in Go 1.26: `case "ios": return "/", nil`), where every other Unix returns an error. go-gh derives the config directory from it (`pkg/config/config.go:250-263`: `GH_CONFIG_DIR`, then `XDG_CONFIG_HOME/gh`, then `$HOME/.config/gh`). Without this line `gh` silently reads and writes `/.config/gh`, and every login appears to vanish. Defaulted to `/var/jb/var/mobile` if unset. |
| `GH_BROWSER` | `cli/browser`'s `browser_darwin.go` runs `open`, which is macOS-only; iOS's equivalent is `uiopen` from `uikittools`. go-gh's launcher precedence (`pkg/browser/browser.go:82-93`) is `GH_BROWSER`, then the `browser` config key, then `BROWSER`, then the platform default. The wrapper sets `GH_BROWSER` to `uiopen` only if neither `GH_BROWSER` nor `BROWSER` is already set, so `gh config set browser …` and an exported variable both still win. |
| `GH_NO_UPDATE_NOTIFIER` | checked at `internal/update/update.go:83`. Otherwise `gh` would tell the user to `brew upgrade gh` (`internal/ghcmd/cmd.go:267`) or download a release. Updates come from apt. |

That is the whole wrapper. There is no `DYLD_*`, no `@executable_path`
library, no `BUN_*`, no environment the binary needs in order to load.

### What this port does not have

Reading both READMEs side by side:

| | CCForiOS (Claude Code) | gh-port |
|---|---|---|
| upstream ships | a macOS binary only, proprietary | MIT source; iOS is a Go target |
| how the iOS binary is made | patch the macOS Mach-O on the device | `go build` with `GOOS=ios` |
| Mach-O patcher | `LC_BUILD_VERSION`, chained-fixup ordinals, 38 path strings | none |
| shim dylib | 68 KB, five symbols, `mmap` interception | none |
| JIT / W^X | load-bearing; `BUN_JSC_useConcurrentJIT=0` or bus error | not applicable |
| entitlements | JIT set | `platform-application`, `no-sandbox`, `get-task-allow` |
| the `.deb` contains | 12 KB of tooling; downloads ~200 MB | the 37 MB binary |
| `postinst` | download, checksum, patch, sign, smoke-test, move | checksum, symlink, smoke-test |
| disk | ~700 MB transient, ~200 MB after | 38 MB |
| network at install | required | none |
| credentials | custom OAuth client, credential kept in a second file | `gh`'s own plaintext fallback |
| on-device verification | tested on iPhone 15 Pro / iOS 17.3 | **not yet** |

## What the package contains

The `.deb` is 9.7 MB and installs to 38 MB (`Installed-Size: 38072`):

| file | installed to | |
|---|---|---|
| `gh` | `/var/jb/usr/local/lib/github-cli/` | the ios/arm64 binary, `ldid`-signed with the entitlements |
| `entitlements.plist` | `/var/jb/usr/local/lib/github-cli/` | kept on device so the binary can be re-signed after a jailbreak update |
| `version.env` | `/var/jb/usr/local/lib/github-cli/` | upstream version, commit, and the binary's SHA-256 |
| `gh-ios` | `/var/jb/usr/local/bin/` | the wrapper |
| `_gh` | `/var/jb/usr/share/zsh/site-functions/` | zsh completion |
| `gh` | `/var/jb/etc/bash_completion.d/` | bash completion |
| `copyright` | `/var/jb/usr/share/doc/com.andi.github-cli/` | upstream's MIT notice, then this packaging's |

`/var/jb/usr/local/bin/gh` is a symlink to `gh-ios`, made by `postinst`.

`postinst` does four things, in this order, and the order is deliberate:

1. **Hash the installed binary against `GH_BINARY_SHA256` in `version.env`.**
   This is not a check on a third party's CDN, as CCForiOS's is — nothing was
   downloaded. It checks that dpkg laid down what was packaged. It runs
   *before* the smoke test rather than instead of it because the two failures
   need different advice: a hash mismatch means a truncated download or a full
   filesystem, and reinstalling fixes it; a hash match followed by a failure
   to exec means iOS rejected the binary, and reinstalling will do nothing.
2. **Take over `gh`.** If a non-symlink `gh` is already at
   `/var/jb/usr/local/bin/gh`, it is kept as `gh-legacy`; `prerm` hands `gh`
   back to it on removal.
3. **Run it.** `gh --version`, through the wrapper, and require the output to
   contain the packaged version. A Go binary that iOS refuses to load dies in
   dyld before `main()`, so this is the only step that catches a bad signature
   or a platform mismatch that every earlier check would pass. The failure
   message suggests `sudo ldid -S…/entitlements.plist …/gh`, which is why the
   plist is shipped. Since nobody has run this binary on a phone yet, this
   step is currently doing real work.
4. Warn if another `gh` is earlier in `PATH` — it would win silently while apt
   reports this one installed and working — and print the sign-in hint if
   `/var/jb/var/mobile/.config/gh/hosts.yml` does not exist.

There is nothing to roll back to and nothing to keep: the previous version's
binary is replaced by dpkg in the usual way, and the repo keeps older packages
for `apt install --allow-downgrades`.

## Updating

There is no custom updater. **APT is the updater**, and `gh`'s own release
notifier is switched off so it does not suggest Homebrew.

### Where the packages come from

Two repositories:

| | |
|---|---|
| `https://reallyitsandi.com/repo/` | the one to add — signed, and carries other packages too |
| `https://realandi.github.io/gh-port/` | where this repository's CI publishes its build |

The domain mirrors from the Pages repo, verifying each package against the
checksum the upstream index declares and keeping the newest few for rollback.
Adding the Pages URL directly also works and gets the same packages a little
sooner; it needs its own key, served as
[`ghport.gpg`](https://realandi.github.io/gh-port/ghport.gpg).

### The workflow

`.github/workflows/publish.yml` runs daily at 07:00 UTC, on
`workflow_dispatch` (optionally with a specific upstream tag), and on pushes to
`main` that touch `packaging/`, `tools/` or the workflow itself. Three jobs:

1. **resolve** (Ubuntu) — ask the GitHub API for `cli/cli`'s latest release
   tag, or take the one given, then `git ls-remote --exit-code` to confirm the
   tag exists. A tag that does not exist would otherwise fail four minutes
   later inside the macOS job, after paying for a checkout and a Go install.
2. **build** (`macos-15`, **mandatory**) — `brew install ldid`, then
   `tools/build-gh.sh`. This has to be macOS: the ios/arm64 port links through
   clang, and clang needs Xcode's iPhoneOS SDK to emit a Mach-O that claims
   platform 2. There is no way to produce this binary on Linux. The binary,
   completions, license text and `gh.version` move to the next job as an
   artifact.
3. **publish** (Ubuntu) — `tools/build-deb.sh` re-runs `check-macho.py` on the
   artifact (a binary that lost its signature crossing the runner boundary
   fails here rather than on a phone), builds the `.deb`,
   `tools/fetch-published.sh` pulls the packages already on the live repo
   forward and keeps the newest 10, and `tools/make-repo.py` regenerates
   `Packages{,.gz,.bz2,.xz}` and `Release`, signs them, and the result deploys
   to GitHub Pages.

Because the package version mirrors upstream, there is no state to track:
Sileo sees a new version exactly when GitHub tags one.

### The revision guard

The package version is `<upstream>-<revision>`, and only upstream moves it. A
change to the wrapper, the `postinst` or the entitlements does not. So
republishing `2.100.0-1` with different content would be invisible — apt sees
a version it already has and offers nobody an upgrade, the fix reaches no
device, and CI stays green.

`build-deb.sh` therefore downloads the already-published `.deb` of the same
version, if there is one, and compares a digest of everything in it except
`gh` itself. If the digests differ it refuses:

```
!! 2.100.0-1 is already published with different content.
   Republishing it would change nothing on anyone's device: apt sees
   the same version and offers no upgrade.

   Bump packaging/revision (currently 1) and rebuild.
```

`gh` is excluded from the comparison because the runner's Go and Xcode both
move under us, so including it would fire the guard on every unrelated
toolchain bump. The version it was built from *is* compared, via `version.env`.

### Manual upgrade and rollback

```sh
sudo apt update && sudo apt install --only-upgrade com.andi.github-cli
sudo apt install --allow-downgrades com.andi.github-cli=2.100.0-1
```

`fetch-published.sh` prunes by version, not by mtime — the carried-forward
packages are downloaded *after* the fresh build and so get newer timestamps
than it, and an mtime sort would prune the newest build first while the
workflow reported success.

### Signing

The published `Release` is signed into `InRelease` and `Release.gpg`. The key
lives in the `GHIOS_GPG_KEY` repository secret (`GHIOS_GPG_KEY_ID` names it)
because a scheduled rebuild has to sign unattended. It is deliberately its own
key — not the one that signs reallyitsandi.com, which never leaves a local
machine, and not CCForiOS's either — so a compromise of this repository's CI
cannot forge packages for the others. If the secret is missing the workflow
publishes unsigned with a warning; Sileo and Zebra accept that, and the `apt`
CLI takes it with `[trusted=yes]`.

## Building it yourself

### Prerequisites

| step | needs |
|---|---|
| `tools/build-gh.sh` | **macOS**: Xcode with the iPhoneOS SDK (`xcrun --sdk iphoneos`), Go, `ldid` (`brew install go ldid`) |
| `tools/build-deb.sh` | `dpkg-deb` (`brew install dpkg` / `apt install dpkg-dev`), `python3` |
| `tools/make-repo.py` | `python3`, `dpkg-deb`; `gpg` to sign |

Only the first step needs macOS. Go's `go.mod` carries a `toolchain`
directive, so an older local Go fetches the one `gh` wants.

### Build

```sh
# 1. The binary, completions, license and gh.version: packaging/payload/
./tools/build-gh.sh                  # or: ./tools/build-gh.sh v2.100.0

# 2. The package: repo/debs/com.andi.github-cli_<version>-<revision>_iphoneos-arm64.deb
./tools/build-deb.sh                 # revision defaults to packaging/revision

# 3. APT metadata: repo/Packages{,.gz,.bz2,.xz} and repo/Release
python3 tools/make-repo.py repo
```

`build-gh.sh` clones the tag at depth 1 (or uses `GH_SRC` if set), stamps
`build.Version` and `build.Date` the way upstream does — the date from the
commit date, and `SOURCE_DATE_EPOCH` likewise — so rebuilding a tag is
reproducible, then signs with `ldid -S packaging/payload/entitlements.plist`
and runs `check-macho.py`.

Completions come from a throwaway **host** build (`GOOS=darwin`) of the same
source, because the iOS binary cannot be run on the build machine. Cobra's
completion scripts are static text and identical whichever `GOOS` produced
them. The host binary is never packaged.

`build-deb.sh` reads the version from `packaging/payload/gh.version`, which
`build-gh.sh` writes, so the two cannot disagree about what was compiled. Set
`GH_REPO` (`owner/name`) and `GH_PAGES` (`owner.github.io/name`) to fill in the
`Icon:` and `Depiction:` fields and to enable the revision guard; without them
those fields are dropped and the guard is skipped.

### Testing a repo locally before publishing

On the Mac, serve the repo:

```sh
cd repo && python3 -m http.server 8000
```

On the device:

```sh
echo 'deb [trusted=yes] http://<mac-ip>:8000/ ./' | sudo tee /var/jb/etc/apt/sources.list.d/gh-port-local.list
sudo apt update
sudo apt install com.andi.github-cli
gh --version
```

`[trusted=yes]` because a local build is unsigned. This is the first thing to
do with this project — see [Status](#status-what-is-verified-and-what-is-not).

### Publishing your own fork

1. Push the repo to GitHub.
2. Settings → Pages → Source: **GitHub Actions**.
3. Optional, to sign it — generate a key and add it as two secrets:

   ```sh
   gpg --quick-generate-key "Your Repo <you@example.com>" rsa4096 sign never
   FPR=$(gpg --fingerprint --with-colons "Your Repo" | awk -F: '/^fpr:/{print $10; exit}')
   gpg --export-secret-keys --armor "$FPR" | gh secret set GHIOS_GPG_KEY --repo <owner>/gh-port
   gh secret set GHIOS_GPG_KEY_ID --repo <owner>/gh-port --body "$FPR"
   ```

4. Run the **build and publish repo** workflow, or wait for the daily run.

The workflow discovers its own Pages URL, so nothing needs editing for a fork.
To force a rebuild without a new upstream release — after a wrapper change, for
instance — bump `packaging/revision`.

### Layout

```
packaging/DEBIAN/control.in          control template (@VERSION@, @ISIZE@, @REPO@, @PAGES@)
packaging/DEBIAN/postinst            hash-check, take over `gh`, smoke-test
packaging/DEBIAN/prerm               hand `gh` back to gh-legacy
packaging/payload/gh-ios             the wrapper
packaging/payload/entitlements.plist three keys, and comments on the absent ones
packaging/payload/version.env.in     filled in by build-deb.sh
packaging/payload/gh                 the binary (built; gitignored)
packaging/payload/completions/       _gh, gh.bash (built; gitignored)
packaging/payload/gh.LICENSE         upstream's MIT text (built; gitignored)
packaging/payload/gh.version         "<version> <commit> <date>" (built; gitignored)
packaging/revision                   package revision; bump to force a rebuild
packaging/depiction.html, index.html copied into the published repo
tools/build-gh.sh                    the cross-compile (macOS only)
tools/clangwrap.sh                   clang → iPhoneOS SDK; the reason there is no patcher
tools/check-macho.py                 platform, dylib allow-list, signature; pure stdlib
tools/build-deb.sh                   the .deb, plus the revision guard
tools/fetch-published.sh             carry published versions forward
tools/make-repo.py                   Packages + Release + signing
tools/make-icon.py                   assets/icon.png, pure stdlib
repo/                                generated APT repo (deployed to Pages; gitignored)
.github/workflows/publish.yml        resolve → build (macOS) → publish
```

## Known limitations

* **The token is plain text on disk**, in `~/.config/gh/hosts.yml`. See
  [Where the token goes](#where-the-token-goes). This will not change unless
  go-keyring stops shelling out to `/usr/bin/security` on darwin.
* **Extensions do not work in either form**, and the two halves fail for
  different reasons and at different stages.

  *Script extensions fail at exec, on device.* A Go process on iOS cannot
  `execve` a file with a shebang: the child returns `EPERM`, whatever the
  interpreter (`sh`, `zsh` and `python3` were all tried) and wherever the file
  lives. A one-line shell extension gives
  `failed to run extension: fork/exec …: operation not permitted`, while the
  very same file runs fine when the shell invokes it. This is specific to Go's
  fork+exec and not to this package: `env`, `zsh` and `git` all exec that
  script without complaint, and re-signing `gh` with every combination of
  entitlements — none at all, `platform-application` only, with and without
  `get-task-allow` — changes nothing. It is not about being outside the
  trustcache either: a re-signed `env`, whose cdhash no longer matches, still
  execs the script. `gh` exec'ing a *signed Mach-O* out of that same directory
  works, so it is the shebang path specifically.

  *Binary extensions fail at install.* `gh extension install` looks for a
  release asset named for `fmt.Sprintf("%s-%s", runtime.GOOS, runtime.GOARCH)`
  (`pkg/cmd/extension/manager.go:73`), which is `ios-arm64`, and no extension
  publishes one. Faking the string as `darwin-arm64` is deliberately not done:
  it would download macOS Mach-Os that then need the full CCForiOS patch
  treatment — platform rewrite, path rewrite, possibly a shim — before iOS
  would load them.

  Two things do work as substitutes, both confirmed on device. A hand-built,
  `ldid`-signed `ios/arm64` binary dropped at
  `~/.local/share/gh/extensions/gh-<name>/gh-<name>` runs normally. And `gh`
  shell aliases work, because `gh` execs a shell *binary* and hands it the
  script as an argument rather than exec'ing a script file:
  `gh alias set gitver '!git --version'` then `gh gitver` returns
  `git version 2.39.1`.
* **`gh copilot` cannot install its helper**, for the same reason as binary
  extensions (`pkg/cmd/copilot/copilot.go:240` builds the download platform
  from `runtime.GOOS`).
* Those are the only places `runtime.GOOS` matters. Every other
  `runtime.GOOS` branch in the gh codebase is a Windows special case.
* `gh`'s update notifier is off, so `gh` will not tell you a newer release
  exists. apt will.
* `/var/jb/usr/local/bin` is on the PATH of a login shell only; over SSH use
  `zsh -l -c` or the full path.
* Requires a rootless jailbreak (`/var/jb`) and iOS 15.0+ (the real floor —
  `SecTrustCopyCertificateChain`).

## Status: what is verified and what is not

Verified on **iPhone 15 Pro** (`iPhone16,1`, A17 Pro), **iOS 17.3** (21D50),
rootless `/var/jb` — installed from the `.deb` through `dpkg`, not side-loaded.

**On the build machine:**

* The unmodified `cli/cli` v2.100.0 source cross-compiles for `ios/arm64` in
  about 27 s.
* The Mach-O shape: platform 2, minos 15.0, sdk 26.5, the four dylibs above at
  their iOS paths, 154 imports all resolvable against the iPhoneOS SDK,
  `LC_CODE_SIGNATURE` present after `ldid`. Both the correct build and the
  wrong-SDK build were produced and inspected; `check-macho.py` accepts the
  first and rejects the second.
* `postinst` and `prerm` were run against a fake root across eight scenarios:
  clean install, hash mismatch, a binary that will not exec, a wrong
  `--version`, taking over an existing `gh`, removal handing the name back,
  reinstall while signed in, and repeated runs.

**On the device:**

* **Installs.** `dpkg -i` unpacks and `postinst` runs on device: the hash check
  passes, the `gh` symlink is created, and the `gh --version` smoke test
  succeeds. `dpkg -V` reports every file matching afterwards.
* **Runs.** `gh version 2.100.0 (2026-09-03)`, exit 0. Nothing on stderr,
  `runtime/cgo: no main bundle` never appears, and the working directory is
  preserved — `init_working_dir` does not `chdir`, which is what makes
  repository detection from `cwd` work.
* **The wrapper does its job.** Inside `gh`, `HOME=/var/jb/var/mobile`,
  `GH_BROWSER=/var/jb/usr/bin/uiopen`, `GH_NO_UPDATE_NOTIFIER=1`.
* **Network.** With a deliberately invalid token, `gh api user` reaches
  `api.github.com` over HTTP/2 and returns `401 Bad credentials` in 57.7 ms —
  DNS through libresolv, the TLS handshake, and x509 chain verification
  through Security.framework all work.
* **Sign-in, end to end.** `gh auth login` used the device flow (confirming
  `DetectFlow`'s preference by observation; the `127.0.0.1` callback is never
  reached on GitHub.com), and completed with exactly the predicted fallback:

  ```
  ✓ Authentication complete.
  ! Authentication credentials saved in plain text
  ✓ Logged in as <user>
  ```

  `gh auth status` in a fresh process reads the token back and names
  `~/.config/gh/hosts.yml` as its source. The keyring miss is fast, not the
  60 s timeout: `gh auth status` returns in 148 ms, and `/usr/bin/security` is
  confirmed absent.
* **The API surface.** REST (`gh api user`), GraphQL (`gh repo view --json`),
  `gh pr list`, `gh issue list`, `gh run list`, `gh search repos` all return
  real data.
* **git integration.** `gh repo clone` over HTTPS, repository detection from
  `cwd` inside the clone, and `gh pr checkout` creating a tracking branch.
  (`gh pr checkout` fails on a `--depth 1` clone with `starting point … is not
  a branch` — that is ordinary shallow-clone behaviour, not iOS.)
* **The TUI.** `gh repo garden` — a full-screen tview application — renders
  correctly under a pty: alternate screen, spinner, colour, status line. The
  interactive survey prompt (`Where do you use GitHub?` with arrow-key
  selection) renders and accepts input. This was the least predictable part of
  the port and it works.
* **Extensions and aliases**, as described under
  [Known limitations](#known-limitations): script extensions fail with `EPERM`,
  a signed `ios/arm64` binary extension runs, and `!` shell aliases work.

One incidental find worth writing down: **`/bin/sh` does not exist** on a
rootless jailbreak. Only `/var/jb/bin/sh` and `/var/jb/usr/bin/sh` do, so any
script carrying a `#!/bin/sh` shebang fails with `ENOENT` before it starts.
Everything in this repository uses `#!/var/jb/usr/bin/zsh`.

**Still not exercised:**

* **Anything that writes to GitHub** — `gh pr create`, `gh issue create`,
  `gh release create`, `gh repo create`. The read path is well covered; the
  write path has only been tested to the point of rendering its prompts.
* **`gh run watch`**, which needs a workflow actually in progress.
* **SSH-protocol remotes.** The clone tests used HTTPS; `git@github.com`
  remotes and `gh auth setup-git` were not tried.
* **Codespaces and `gh copilot`**, the latter for the reason under
  [Known limitations](#known-limitations).

## License

The packaging, wrapper and tooling in this repository are MIT licensed
([LICENSE](LICENSE)). `gh` itself is MIT licensed by GitHub Inc., which is why
the binary can ship in the package; upstream's notice travels with it at
`/var/jb/usr/share/doc/com.andi.github-cli/copyright`.
