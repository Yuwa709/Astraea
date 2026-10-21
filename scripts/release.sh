#!/bin/bash
# Build, sign with Developer ID, notarize, staple, package, and sign an
# appcast for one Astraea release.
#
# Produces three artifacts in dist/ and publishes NOTHING:
#
#   Astraea-<version>.dmg   first-time installs, with an /Applications symlink
#   Astraea-<version>.zip   Sparkle updates
#   appcast.xml              the signed feed Sparkle reads
#
# Both packages come from ONE signed .app. Signing twice would produce two
# bundles with different signatures for the same release, and whichever one a
# user did not install would fail Sparkle's validation later.
#
# The DMG still matters even with Sparkle wired: Sparkle only updates an app
# somebody already has. First installs come through the DMG and pass
# Gatekeeper because both it and the app inside are notarized and stapled.
#
# Uploads go only to Apple's notary service (notarytool, keychain profile
# $NOTARY_PROFILE, default AC_PASSWORD).
# Publishing is a deliberate, separate act: upload both packages to a GitHub
# Release tagged v<version>, then commit appcast.xml to the repo root on main,
# which is where SUFeedURL points.
#
# Usage: scripts/release.sh 1.1
#        scripts/release.sh 1.1 --sign-only
#
# --sign-only stops after build, sign, verify and the launch smoke test. It
# writes nothing to dist/, never notarizes, never touches the EdDSA key or
# appcast.xml, and does not need generate_appcast or notary credentials. Use it
# to check a signing change without cutting a release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
SIGN_ONLY=0
for ARG in "$@"; do
    case "$ARG" in
        --sign-only) SIGN_ONLY=1 ;;
        -*) echo "!! Unknown option: $ARG" >&2; exit 1 ;;
        *)
            if [[ -n "$VERSION" ]]; then
                echo "!! More than one version given: '$VERSION' and '$ARG'" >&2
                exit 1
            fi
            VERSION="$ARG"
            ;;
    esac
done
if [[ -z "$VERSION" ]]; then
    echo "!! Usage: scripts/release.sh <version> [--sign-only]   (e.g. 1.1)" >&2
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    # Sparkle compares versions itself, but a stray "v" or a suffix makes
    # CFBundleVersion sort unpredictably against previously shipped builds.
    echo "!! Version must be digits and dots only, no leading v: got '$VERSION'" >&2
    exit 1
fi

REPO="Yuwa709/Astraea"
DIST="dist"
ZIP="$DIST/Astraea-$VERSION.zip"
DMG="$DIST/Astraea-$VERSION.dmg"
STAGING="$DIST/staging"
ENTITLEMENTS="Astraea/Astraea.entitlements"

# --- signing identity --------------------------------------------------------
# Releases are signed with the Developer ID Application certificate for team
# 4KUMGQ48T9 and notarized (decided 2026-10-21, PROJECT-CONTEXT.md,
# Distribution). History: ad-hoc up to 1.3.1, whose designated requirement is a
# bare cdhash, so every update reset the Accessibility grant and the Face
# Unlock keychain ACL; then a self-signed cert, which gave a stable requirement
# but no Team ID and no Gatekeeper approval. Developer ID gives all three.
#
# The designated requirement is pinned to the TEAM, not to one certificate:
#     identifier "com.techie.Astraea" and anchor apple generic and ...
#     certificate leaf[subject.OU] = "4KUMGQ48T9"
# so a renewed Developer ID cert (they last five years) keeps every user's
# grants. That is why there is no SHA-1 pin here any more; the DR check below
# is the guard that matters.
#
# Looked up by exact Common Name, WITH -v: an Apple-issued cert must be
# trusted, and -v drops an expired one left behind after a renewal.
#
# There is NO fallback. Never ad-hoc, never the self-signed cert, never the
# Apple Development certificate, a personal credential that must not sign a
# shipped build.
TEAM_ID="4KUMGQ48T9"
SIGN_NAME="Developer ID Application: Joshua Pham ($TEAM_ID)"
echo "==> Locating signing identity"
SIGN_SHA1S=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v want="\"$SIGN_NAME\"" \
        'index($0, want) && length($2) == 40 && $2 ~ /^[0-9A-F]+$/ { print $2 }' \
    | sort -u)
SIGN_COUNT=$(grep -c . <<<"$SIGN_SHA1S" || true)
if [[ "$SIGN_COUNT" -eq 0 ]]; then
    cat >&2 <<MSG
!! No valid code-signing identity named "$SIGN_NAME" in the keychain.

   Releases must be signed with it, and this script will not fall back to
   ad-hoc or to any other certificate. Download it from
   developer.apple.com > Certificates (or Xcode > Settings > Accounts >
   Manage Certificates), then re-run. Check with:
       security find-identity -v -p codesigning
MSG
    exit 1
fi
if [[ "$SIGN_COUNT" -ne 1 ]]; then
    echo "!! More than one valid identity named \"$SIGN_NAME\":" >&2
    sed 's/^/   /' <<<"$SIGN_SHA1S" >&2
    echo "   Delete the stray one in Keychain Access; the cert must be unambiguous." >&2
    exit 1
fi
SIGN_SHA1="$SIGN_SHA1S"
echo "    $SIGN_NAME ($SIGN_SHA1)"

# --- notary credentials --------------------------------------------------------
# Stored once with
#     xcrun notarytool store-credentials "AC_PASSWORD" \
#         --apple-id <apple id> --team-id 4KUMGQ48T9
# in a real terminal (the password prompt needs a TTY). Checked up front so a
# missing profile fails in seconds rather than after the build.
# --sign-only never notarizes, so it does not need the profile.
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
if [[ "$SIGN_ONLY" -eq 0 ]]; then
echo "==> Checking notary credentials"
if ! NOTARY_CHECK=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1); then
    echo "!! notarytool cannot use keychain profile \"$NOTARY_PROFILE\":" >&2
    sed 's/^/   /' <<<"$NOTARY_CHECK" >&2
    echo "   Store it with the store-credentials command in this script's comments." >&2
    exit 1
fi
echo "    keychain profile \"$NOTARY_PROFILE\" OK"
fi

# --- generate_appcast, located dynamically -----------------------------------
# It ships inside the resolved SPM artifact, whose path contains a DerivedData
# hash that changes and which a clean build deletes. Never hardcode it.
# --sign-only never reaches the appcast step, so it does not need the tool.
if [[ "$SIGN_ONLY" -eq 0 ]]; then
echo "==> Locating Sparkle tools"
GENERATE_APPCAST=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*/artifacts/sparkle/Sparkle/bin/generate_appcast" -type f 2>/dev/null | head -1)
if [[ -z "$GENERATE_APPCAST" ]]; then
    cat >&2 <<'MSG'
!! Could not find Sparkle's generate_appcast.

   It lives in the resolved Swift Package artifacts under DerivedData, which a
   clean build removes. To restore it, open Astraea.xcodeproj and either:
       File > Packages > Resolve Package Versions
   or build the app once. Then re-run this script.
MSG
    exit 1
fi
echo "    $GENERATE_APPCAST"
fi

# --- launch smoke test ---------------------------------------------------
# The check that would have caught 1.0.0. A signature can be individually valid
# on every component and still refuse to load — only actually starting the
# process proves dyld accepts it. Briefly runs a second Astraea, which draws
# its own notch panel for a few seconds before being killed.
smoke_launch() {
    local app="$1" label="$2" err pid
    err=$(mktemp)
    "$app/Contents/MacOS/Astraea" >/dev/null 2>"$err" &
    pid=$!
    sleep 4
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        # Let the kernel release the volume this ran from before any detach.
        sleep 1
        rm -f "$err"
        echo "    launch OK: $label"
    else
        echo "!! LAUNCH FAILED: $label" >&2
        echo "   The bundle is signed but dyld will not run it:" >&2
        sed 's/^/   /' "$err" >&2
        rm -f "$err"
        exit 1
    fi
}

# --- build -------------------------------------------------------------------
# CFBundleShortVersionString and CFBundleVersion come from these two build
# settings (GENERATE_INFOPLIST_FILE synthesizes the plist from them); neither
# lives in Astraea/Info.plist, which carries only the custom Sparkle keys.
# Overriding them here is what makes CFBundleVersion match sparkle:version in
# the appcast, since generate_appcast reads CFBundleVersion out of the app.
#
# CODE_SIGN_IDENTITY="-" makes the build itself ad-hoc. Without it, Automatic
# signing picks the Apple Development certificate, which is a personal
# credential that must never ship. The ad-hoc build is only an intermediate:
# the explicit re-sign below replaces every signature in the bundle with the
# release identity, and the checks after it prove nothing ad-hoc survived.
#
# CLANG_COVERAGE_MAPPING=NO keeps coverage instrumentation out of the release.
# No scheme is committed, so xcodebuild generates one, and that scheme injects
# CLANG_COVERAGE_MAPPING=YES into every configuration it builds — Release
# included. Up to 1.0.6 that shipped profile counters and the LLVM profile
# runtime, and left a default.profraw in the working directory on exit.
# A command-line override outranks the scheme. Test runs never pass through
# here, so they keep coverage. The binary is checked for it below.
#
# No `clean`: it is not needed for correctness and risks removing the SPM
# artifacts that generate_appcast lives in.
# The full test suite gates every release. 1.4.0 shipped with Face Unlock
# unable to load its model while testBundledModelMatchesThePinnedDigest was
# failing; running it here would have stopped that release.
# --sign-only skips it: it checks signing, not the app.
if [[ "$SIGN_ONLY" -eq 0 ]]; then
echo "==> Running tests"
TEST_LOG=$(mktemp)
if ! xcodebuild -scheme Astraea -destination 'platform=macOS' test >"$TEST_LOG" 2>&1; then
    grep -E "Test case .* failed|error:" "$TEST_LOG" | sed 's/^/   /' >&2 || true
    echo "!! Tests failed (full log: $TEST_LOG). Refusing to release." >&2
    exit 1
fi
rm -f "$TEST_LOG"
echo "    all tests passed"
fi

echo "==> Building Release $VERSION"
xcodebuild -scheme Astraea -configuration Release -destination 'platform=macOS' \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    CLANG_COVERAGE_MAPPING=NO \
    build | grep -E "error:|warning: (unable|failed)|BUILD (SUCCEEDED|FAILED)" || true

BUILT_DIR=$(xcodebuild -scheme Astraea -configuration Release -destination 'platform=macOS' \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ { print $2; exit }')
APP="$BUILT_DIR/Astraea.app"
if [[ ! -d "$APP" ]]; then
    echo "!! No built app at $APP" >&2
    exit 1
fi
echo "    $APP"

# --- sign with the release identity, inside out ------------------------------
# Order matters: nested code must be signed before its container, or sealing
# the container captures a hash that the later nested signature invalidates.
#
# --preserve-metadata=entitlements on the Sparkle components: Autoupdate ships
# com.apple.application-identifier, and re-signing without it would silently
# drop it. The app instead gets its entitlements file explicitly, because
# com.apple.security.automation.apple-events is load-bearing — Hardened Runtime
# refuses Apple Events without it and the media feature dies with a silent
# -1743, no prompt and no Automation pane entry.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

# No disable-library-validation. Up to 1.3.2 the release build needed it:
# Library Validation demands every loaded library share the main executable's
# Team ID, and neither ad-hoc nor the self-signed cert had one, so dyld refused
# Sparkle.framework ("different Team IDs", the 1.0.0 launch failure). Signing
# app and frameworks with the one Developer ID gives them all team 4KUMGQ48T9,
# so library validation passes on its own. The team ID check and the launch
# smoke test below prove it on every release.
#
# --timestamp: a secure timestamp from Apple's server is mandatory for
# notarization, and keeps the signature valid after the certificate expires.
# It needs the network.
echo "==> Signing with $SIGN_NAME"
for COMPONENT in \
    "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$FRAMEWORK/Versions/B/Updater.app" \
    "$FRAMEWORK/Versions/B/Autoupdate"
do
    [[ -e "$COMPONENT" ]] || { echo "!! Missing $COMPONENT" >&2; exit 1; }
    codesign -f -s "$SIGN_SHA1" -o runtime --timestamp \
        --preserve-metadata=entitlements "$COMPONENT"
    echo "    signed $(basename "$COMPONENT")"
done
codesign -f -s "$SIGN_SHA1" -o runtime --timestamp "$FRAMEWORK"
echo "    signed Sparkle.framework"

# --- vendored mediaremote-adapter --------------------------------------------
# Browser now-playing (Chrome, Safari) comes from ungive/mediaremote-adapter,
# vendored under vendor/ and embedded by Xcode copy phases. Provenance and
# terms are in THIRD-PARTY-LICENSES.md.
#
# These are leaves, exactly like the Sparkle components above, and are signed
# before the app for the same reason: sealing the app captures a hash that a
# later nested signature would invalidate.
#
# No --preserve-metadata=entitlements and no --entitlements file. Both objects
# ship unentitled and must stay that way. The adapter framework is never loaded
# into Astraea -- mediaremote-adapter.pl dlopens it into /usr/bin/perl, which
# is Apple-signed as com.apple.perl, and THAT identity is the only reason
# MediaRemote answers at all. Entitling these would be notarization risk for no
# gain (CLAUDE.md, distribution).
ADAPTER_FRAMEWORK="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
ADAPTER_BINARY="$ADAPTER_FRAMEWORK/Versions/A/MediaRemoteAdapter"
ADAPTER_TEST_CLIENT="$APP/Contents/MacOS/MediaRemoteAdapterTestClient"
ADAPTER_SCRIPT="$APP/Contents/Resources/mediaremote-adapter.pl"

for ITEM in "$ADAPTER_BINARY" "$ADAPTER_TEST_CLIENT" "$ADAPTER_SCRIPT"; do
    [[ -e "$ITEM" ]] || {
        echo "!! Missing $ITEM" >&2
        echo "   The Xcode copy phases for vendor/ did not run. Refusing to package." >&2
        exit 1
    }
done

# install_name_tool BEFORE codesign, never after: it rewrites the Mach-O and
# invalidates any signature already applied. It warns about exactly that, which
# is why its output is captured and only surfaced on failure.
#
# WHY IT IS NEEDED: upstream's CMake build hardcodes LC_ID_DYLIB to
# /opt/homebrew/opt/media-control/Frameworks/..., a path that does not exist on
# a user's machine. Nothing links against this framework -- the perl script
# dlopens it by absolute path, so the install name is never resolved and the
# stale value would not actually break loading. It is rewritten anyway because
# a Homebrew path baked into a shipped, notarized bundle reads as a broken
# dependency to tooling and to anyone auditing the binary.
if ! INT_OUTPUT=$(install_name_tool -id \
    "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
    "$ADAPTER_BINARY" 2>&1)
then
    echo "!! install_name_tool failed on the adapter framework:" >&2
    echo "$INT_OUTPUT" >&2
    exit 1
fi
echo "    rewrote MediaRemoteAdapter install name"

codesign -f -s "$SIGN_SHA1" -o runtime --timestamp "$ADAPTER_FRAMEWORK"
echo "    signed MediaRemoteAdapter.framework"
codesign -f -s "$SIGN_SHA1" -o runtime --timestamp "$ADAPTER_TEST_CLIENT"
echo "    signed MediaRemoteAdapterTestClient"

codesign -f -s "$SIGN_SHA1" -o runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$APP"
echo "    signed Astraea.app"

# --- verify ------------------------------------------------------------------
# This is the gate. Sparkle rejects an update whose Apple code signature is
# broken (updateIsCodeSigned && !valid), so a bad signature here becomes a
# silent refusal on every user's machine. Catching it is the point of this step.
echo "==> Verifying signature"
if ! codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'; then
    echo "!! codesign --verify --deep --strict FAILED. Refusing to package." >&2
    exit 1
fi

# codesign --verify --deep --strict validates each signature INDIVIDUALLY and
# never checks that nested code is loadable by its container. It passed on the
# broken 1.0.0 build. This does check that.
team_of() { codesign -dv "$1" 2>&1 | awk -F= '/^TeamIdentifier/ { print $2 }'; }
APP_TEAM=$(team_of "$APP")
for NESTED in \
    "Sparkle.framework|$FRAMEWORK" \
    "MediaRemoteAdapter.framework|$ADAPTER_FRAMEWORK"
do
    NESTED_NAME="${NESTED%%|*}"
    NESTED_TEAM=$(team_of "${NESTED##*|}")
    if [[ "$APP_TEAM" != "$NESTED_TEAM" ]]; then
        echo "!! Team ID mismatch: app='$APP_TEAM' $NESTED_NAME='$NESTED_TEAM'." >&2
        echo "   Nested code must share the app's Team ID. Refusing to package." >&2
        exit 1
    fi
done
if [[ "$APP_TEAM" != "$TEAM_ID" ]]; then
    echo "!! App Team ID is '${APP_TEAM:-not set}', expected $TEAM_ID. Refusing to package." >&2
    exit 1
fi
echo "    team IDs agree (app, Sparkle, MediaRemoteAdapter: $APP_TEAM)"

if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "disable-library-validation"; then
    echo "!! disable-library-validation is back in the app's entitlements." >&2
    echo "   With a Developer ID it is an unneeded weakening. Refusing to package." >&2
    exit 1
fi

if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "apple-events"; then
    echo "!! The apple-events entitlement is missing after signing." >&2
    echo "   Media control would fail silently with -1743. Refusing to package." >&2
    exit 1
fi
echo "    apple-events entitlement present"

# The point of the release identity: a designated requirement pinned to the
# team, not to this build's cdhash or to one certificate. Anything else here
# means the identity changed, and every user would lose their grants on this
# update. This is codesign's standard Developer ID requirement, verbatim.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
EXPECTED_DR="identifier \"$BUNDLE_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"$TEAM_ID\""
ACTUAL_DR=$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')
if [[ "$ACTUAL_DR" != "$EXPECTED_DR" ]]; then
    echo "!! Unexpected designated requirement." >&2
    echo "   got:      ${ACTUAL_DR:-<none>}" >&2
    echo "   expected: $EXPECTED_DR" >&2
    echo "   Refusing to package." >&2
    exit 1
fi
echo "    designated => $ACTUAL_DR"

# Every Mach-O in the bundle must carry the release identity and a secure
# timestamp, or the notary service rejects the whole submission. The signing
# above walks a fixed list; code embedded later and missed there would ship
# with Xcode's ad-hoc signature, which --verify --deep accepts silently.
#
# codesign -dvv prints the whole chain, leaf first, so only line one is the
# signer. Taken with `sed -n 1p`, never `head`, which exits early and turns
# SIGPIPE into a failure under pipefail. A secure timestamp prints as
# "Timestamp="; "Signed Time=" is the unauthenticated local clock.
UNSIGNED=0
while IFS= read -r -d '' FILE; do
    file -b "$FILE" | grep -q '^Mach-O' || continue
    DETAILS=$(codesign -dvv "$FILE" 2>&1 || true)
    AUTHORITY=$(sed -n 's/^Authority=//p' <<<"$DETAILS" | sed -n 1p)
    if [[ "$AUTHORITY" != "$SIGN_NAME" ]]; then
        echo "!! ${FILE#"$APP"/} is not signed by $SIGN_NAME (Authority: ${AUTHORITY:-none, so ad-hoc or unsigned})" >&2
        UNSIGNED=1
    elif ! grep -q '^Timestamp=' <<<"$DETAILS"; then
        echo "!! ${FILE#"$APP"/} has no secure timestamp; notarization would reject it" >&2
        UNSIGNED=1
    fi
done < <(find "$APP" -type f -print0)
if [[ "$UNSIGNED" -ne 0 ]]; then
    echo "   Add it to the inside-out signing above. Refusing to package." >&2
    exit 1
fi
echo "    every Mach-O in the bundle signed by $SIGN_NAME, with a secure timestamp"

# Coverage instrumentation must not ship. CLANG_COVERAGE_MAPPING=NO on the
# build line is the fix; this is the proof, read from the binary rather than
# the build settings, so a future Xcode that turns coverage on through some
# other setting still stops here. The counters section survives stripping; the
# ___profc_ symbols survive a renamed section.
#
# Counted with `grep -c`, never `grep -q`: -q exits on the first match, nm dies
# of SIGPIPE, and under pipefail that failure turns a hit into a pass.
BINARY="$APP/Contents/MacOS/Astraea"
if ! LOAD_COMMANDS=$(otool -l "$BINARY") || ! SYMBOLS=$(nm "$BINARY"); then
    echo "!! Could not read $BINARY with otool and nm. Refusing to package." >&2
    exit 1
fi
PRF_CNTS=$(grep -c 'sectname __llvm_prf_cnts' <<<"$LOAD_COMMANDS" || true)
PROFC=$(grep -c '___profc_' <<<"$SYMBOLS" || true)
if [[ "$PRF_CNTS" -ne 0 || "$PROFC" -ne 0 ]]; then
    echo "!! Coverage instrumentation in the built binary:" >&2
    echo "   __llvm_prf_cnts sections: $PRF_CNTS, ___profc_ symbols: $PROFC." >&2
    echo "   A release must not ship profile counters. Refusing to package." >&2
    exit 1
fi
echo "    no coverage instrumentation (no __llvm_prf_cnts section, no ___profc_ symbols)"

# The face model must pass the app's own integrity check, or Face Unlock
# refuses to load it on every user's machine. 1.4.0 shipped exactly that: an
# Xcode update changed the compiler's buildInfo stamp in model.mil, the digest
# moved, and nothing here noticed. Recomputed the way FaceModelIntegrity does
# (shasum lines for the hashed files, then a SHA-256 of those lines) and
# compared against the value pinned in the source.
MODEL_DIR="$APP/Contents/Resources/FaceReidentification.mlmodelc"
INTEGRITY_SRC="Astraea/Modules/FaceUnlock/FaceModelIntegrity.swift"
PINNED_DIGEST=$(sed -n 's/^ *static let expectedDigest = "\([0-9a-f]\{64\}\)"$/\1/p' "$INTEGRITY_SRC")
if [[ -z "$PINNED_DIGEST" || ! -d "$MODEL_DIR" ]]; then
    echo "!! Could not read the pinned face-model digest or find $MODEL_DIR. Refusing to package." >&2
    exit 1
fi
BUILT_DIGEST=$(cd "$MODEL_DIR" && shasum -a 256 ./model.mil ./weights/weight.bin | shasum -a 256 | cut -c1-64)
if [[ "$BUILT_DIGEST" != "$PINNED_DIGEST" ]]; then
    echo "!! Face model digest $BUILT_DIGEST does not match the pin $PINNED_DIGEST" >&2
    echo "   in $INTEGRITY_SRC. Face Unlock would refuse its model." >&2
    echo "   If the model or Xcode changed on purpose, check that weight.bin is" >&2
    echo "   unchanged and re-pin (see the expectedDigest comment). Refusing to package." >&2
    exit 1
fi
echo "    face model digest matches the pin"

BUILT_PLIST="$APP/Contents/Info.plist"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUILT_PLIST")
BUILT_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT_PLIST")
if [[ "$BUILT_VERSION" != "$VERSION" || "$BUILT_SHORT" != "$VERSION" ]]; then
    echo "!! Version mismatch in the built bundle." >&2
    echo "   CFBundleVersion=$BUILT_VERSION CFBundleShortVersionString=$BUILT_SHORT, wanted $VERSION" >&2
    exit 1
fi
echo "    CFBundleVersion=$BUILT_VERSION CFBundleShortVersionString=$BUILT_SHORT"

# A PLACEHOLDER key ships an app that can never accept an update, and the
# failure only shows up on a user's machine.
PUBKEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$BUILT_PLIST" 2>/dev/null || echo "")
if [[ -z "$PUBKEY" || "$PUBKEY" == "PLACEHOLDER" ]]; then
    echo "!! SUPublicEDKey is missing or still PLACEHOLDER. Refusing to package." >&2
    exit 1
fi
echo "    SUPublicEDKey present"

echo "==> Launch smoke test (signed bundle)"
smoke_launch "$APP" "build products"

if [[ "$SIGN_ONLY" -eq 1 ]]; then
    echo
    echo "--sign-only: built, signed and verified $APP"
    echo "Nothing packaged or notarized; dist/ and appcast.xml untouched."
    exit 0
fi

# --- notarize ------------------------------------------------------------------
# Submits to Apple's notary service and waits (usually a few minutes). The
# exit status of `notarytool submit --wait` is not a verdict: an Invalid
# submission still exits 0. The status is read out of the plist instead, and on
# anything but Accepted the notary log, which names each offending file, is
# printed.
notarize() {
    local file="$1" label="$2" out id status
    echo "    submitting $label (waits for Apple)"
    if ! out=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format plist 2>&1); then
        echo "!! notarytool submit failed for $label:" >&2
        sed 's/^/   /' <<<"$out" >&2
        exit 1
    fi
    id=$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null || true)
    status=$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null || true)
    if [[ "$status" != "Accepted" ]]; then
        echo "!! Notarization of $label: ${status:-no status} (submission ${id:-unknown})" >&2
        sed 's/^/   /' <<<"$out" >&2
        if [[ -n "$id" ]]; then
            echo "   Notary log:" >&2
            xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 \
                | sed 's/^/   /' >&2 || true
        fi
        exit 1
    fi
    echo "    accepted: $label (submission $id)"
}

# The app is notarized and stapled BEFORE packaging, so the zip and the DMG
# both carry the ticket and Gatekeeper approves the first launch offline. The
# upload is a throwaway zip; the shipped zip is cut from the stapled app below.
echo "==> Notarizing"
NOTARIZE_DIR=$(mktemp -d)
ditto -c -k --keepParent "$APP" "$NOTARIZE_DIR/Astraea.zip"
notarize "$NOTARIZE_DIR/Astraea.zip" "Astraea.app"
rm -rf "$NOTARIZE_DIR"

xcrun stapler staple -q "$APP"
if ! xcrun stapler validate -q "$APP"; then
    echo "!! Stapled ticket on Astraea.app does not validate. Refusing to package." >&2
    exit 1
fi
echo "    ticket stapled to Astraea.app"

# Gatekeeper's own verdict, the check a user's Mac actually runs.
# "source=Notarized Developer ID" is the only acceptable answer.
gatekeeper_check() {
    local app="$1" label="$2" out
    out=$(spctl -a -vv -t exec "$app" 2>&1 || true)
    if ! grep -q "source=Notarized Developer ID" <<<"$out"; then
        echo "!! Gatekeeper does not accept $label:" >&2
        sed 's/^/   /' <<<"$out" >&2
        exit 1
    fi
    echo "    Gatekeeper accepts $label (Notarized Developer ID)"
}
gatekeeper_check "$APP" "build products"

# --- package -----------------------------------------------------------------
# ditto, not zip: a plain zip does not preserve the extended attributes and
# symlink structure a signed bundle depends on, and breaks the signature.
echo "==> Packaging"
rm -rf "$DIST"
mkdir -p "$STAGING"

# Both packages are cut from $APP, which was signed exactly once above.
# ditto preserves the signature; nothing here re-signs.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
LENGTH=$(stat -f%z "$ZIP")
echo "    $ZIP ($LENGTH bytes)"

ditto "$APP" "$STAGING/Astraea.app"
# The drag-to-install target users expect in a DMG window.
ln -s /Applications "$STAGING/Applications"

# --- styled DMG window ---------------------------------------------------------
# The window a user sees on opening the DMG: a night-sky background drawn by
# scripts/dmg-background.swift, the app icon on the left and Applications on
# the right with an arrow between them, no toolbar, and Astraea's icon as the
# volume icon. Finder stores that layout in the volume's .DS_Store, and the
# only supported way to write it is to have Finder lay out a mounted
# read-write image, hence the AppleScript. The positions here must match the
# constants in dmg-background.swift.
#
# Needs Automation permission for whatever runs this script to control
# Finder; macOS asks the first time.
VOLNAME="Astraea $VERSION"
if mount | grep -q " on /Volumes/$VOLNAME "; then
    echo "!! A volume named \"$VOLNAME\" is already mounted. Eject it and re-run." >&2
    exit 1
fi
mkdir "$STAGING/.background"
BG_DIR=$(mktemp -d)
swift scripts/dmg-background.swift "$BG_DIR"
# One HiDPI TIFF, so Retina screens get the @2x art.
tiffutil -cathidpicheck "$BG_DIR/background.png" "$BG_DIR/background@2x.png" \
    -out "$STAGING/.background/background.tiff" >/dev/null 2>&1
rm -rf "$BG_DIR"

RW_DMG="$DIST/rw.dmg"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -fs HFS+ \
    -ov -format UDRW "$RW_DMG" >/dev/null
rm -rf "$STAGING"
RW_MOUNT=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen \
    | awk -F'\t' '/\/Volumes\// { print $NF; exit }')
if [[ "$RW_MOUNT" != "/Volumes/$VOLNAME" ]]; then
    echo "!! Read-write image mounted at '${RW_MOUNT:-nowhere}', expected /Volumes/$VOLNAME." >&2
    [[ -n "$RW_MOUNT" ]] && hdiutil detach "$RW_MOUNT" -force -quiet || true
    exit 1
fi

# Bounds include the title bar, so 660x400 of content needs ~28 more points.
if ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Astraea.app" of container window to {170, 190}
        set position of item "Applications" of container window to {490, 190}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
then
    hdiutil detach "$RW_MOUNT" -force -quiet || true
    echo "!! Finder could not lay out the DMG window. If macOS denied Automation" >&2
    echo "   access to Finder, allow it in System Settings > Privacy & Security >" >&2
    echo "   Automation, then re-run." >&2
    exit 1
fi
[[ -f "$RW_MOUNT/.DS_Store" ]] || { echo "!! Finder wrote no .DS_Store; the layout would be lost." >&2; exit 1; }
# The volume icon goes on last: hdiutil create -srcfolder leaves
# .VolumeIcon.icns out, and Finder deletes it during the layout above
# (seen on macOS 27, 2026-10-21).
cp "$APP/Contents/Resources/AppIcon.icns" "$RW_MOUNT/.VolumeIcon.icns"
SetFile -a C "$RW_MOUNT"
sync
detach_rw() {
    local i
    for i in 1 2 3 4 5; do
        hdiutil detach "$RW_MOUNT" -quiet 2>/dev/null && return 0
        sleep 1
    done
    hdiutil detach "$RW_MOUNT" -force -quiet
}
detach_rw
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"
echo "    styled DMG window laid out"

# The DMG is a container a browser quarantines, so it gets its own signature,
# notarization and ticket. The app inside is already stapled; this makes the
# disk image itself open without a Gatekeeper prompt. No `-o runtime`: that is
# for executables, not disk images.
codesign -f -s "$SIGN_SHA1" --timestamp "$DMG"
notarize "$DMG" "$(basename "$DMG")"
xcrun stapler staple -q "$DMG"
if ! xcrun stapler validate -q "$DMG"; then
    echo "!! Stapled ticket on $DMG does not validate. Refusing to publish." >&2
    exit 1
fi
echo "    $DMG ($(stat -f%z "$DMG") bytes, signed, notarized, stapled)"

# Prove the signature survived each round trip, rather than assuming it. A
# signature that breaks in packaging is invisible until a user's machine
# refuses the app or Sparkle refuses the update.
VERIFY_DIR=$(mktemp -d)
# Resolved with pwd -P: mktemp hands back /var/folders/..., but `mount` reports
# the same volume as /private/var/folders/..., so an unresolved path never
# matches the mount table and the cleanup below would try to rm a live volume.
MOUNT_DIR=$(cd "$(mktemp -d)" && pwd -P)
# Detaching right after killing a process launched FROM the volume fails: the
# kernel has not released it yet, and a plain `rm -rf` then tries to delete a
# still-mounted read-only volume and spews errors. Retry, force, and never
# remove a path that is still a mountpoint.
detach_dmg() {
    local point="$1" i
    for i in 1 2 3 4 5; do
        mount | grep -q " on $point " || return 0
        hdiutil detach "$point" -quiet 2>/dev/null && return 0
        sleep 1
    done
    hdiutil detach "$point" -force -quiet 2>/dev/null || true
}
cleanup() {
    detach_dmg "$MOUNT_DIR"
    rm -rf "$VERIFY_DIR"
    mount | grep -q " on $MOUNT_DIR " || rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

ditto -x -k "$ZIP" "$VERIFY_DIR"
if ! codesign --verify --deep --strict "$VERIFY_DIR/Astraea.app" 2>&1 | sed 's/^/    /'; then
    echo "!! Signature broke during zip packaging. Refusing to publish." >&2
    exit 1
fi
echo "    signature intact after unzip"
gatekeeper_check "$VERIFY_DIR/Astraea.app" "unzipped"
smoke_launch "$VERIFY_DIR/Astraea.app" "unzipped"

hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT_DIR"
if ! codesign --verify --deep --strict "$MOUNT_DIR/Astraea.app" 2>&1 | sed 's/^/    /'; then
    echo "!! Signature broke during DMG packaging. Refusing to publish." >&2
    exit 1
fi
echo "    signature intact inside DMG"
gatekeeper_check "$MOUNT_DIR/Astraea.app" "inside DMG"
smoke_launch "$MOUNT_DIR/Astraea.app" "inside DMG"
detach_dmg "$MOUNT_DIR"

# --- appcast -----------------------------------------------------------------
# Signs the zip with the private EdDSA key from the login keychain and writes
# appcast.xml. The download prefix must match where the asset will actually be
# uploaded, or Sparkle downloads a 404.
# generate_appcast treats EVERY archive in the directory it is given as a
# candidate update, and refuses two that carry the same bundle version — so
# pointing it at dist/ once the DMG exists fails with "Duplicate updates are
# not supported". It gets its own directory holding only the zip, hardlinked
# so nothing is copied. Sparkle updates ship as the zip; the DMG is for humans
# and must stay out of the feed.
echo "==> Generating appcast"
APPCAST_SRC="$DIST/appcast-src"
mkdir -p "$APPCAST_SRC"
ln "$ZIP" "$APPCAST_SRC/$(basename "$ZIP")"
"$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO" \
    "$APPCAST_SRC"

APPCAST="$DIST/appcast.xml"
mv "$APPCAST_SRC/appcast.xml" "$APPCAST"
rm -rf "$APPCAST_SRC"
[[ -f "$APPCAST" ]] || { echo "!! generate_appcast produced no appcast.xml" >&2; exit 1; }

if ! grep -q 'sparkle:edSignature' "$APPCAST"; then
    echo "!! appcast.xml has no EdDSA signature. Sparkle would reject this update." >&2
    exit 1
fi

echo
echo "=============================================================="
echo "  dmg      $DMG        (first installs)"
echo "  zip      $ZIP   ($LENGTH bytes, Sparkle updates)"
echo "  appcast  $APPCAST"
echo "=============================================================="
echo
echo "Nothing has been uploaded. To publish:"
echo "  1. Create a GitHub Release tagged v$VERSION on $REPO"
echo "  2. Attach BOTH $DMG and $ZIP as release assets"
echo "     (the appcast's enclosure URL points at the zip; the DMG is for humans)"
echo "  3. Copy $APPCAST to the repo root and commit it to main"
echo "     (SUFeedURL reads it from raw.githubusercontent.com/$REPO/main/appcast.xml)"
