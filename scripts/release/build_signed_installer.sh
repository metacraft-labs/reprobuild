#!/bin/sh
# Build, sign (and, for the .pkg, notarize) one installer package for a
# release leg, in STAND-IN or PRODUCTION mode, and say which.
#
#   build_signed_installer.sh --ecosystem pkg|msi --out <dir> \
#       (--version <v> --archive <release archive> [--platform <p>] [--asset-arch <a>]
#        | --package <an unsigned .pkg/.msi>)
#
# Writes into <dir>:
#   <asset>                          the signed package
#   <asset>.sha256                   `<digest>  <asset>` (GNU text form)
#   <asset>.signing-report.txt       mode, certificate, tools, every check
#   <asset>.SIGNED-WITH-A-TEST-CERTIFICATE, <asset>.stand-in-root.pem
#                                    in stand-in mode only (the public root,
#                                    so the package can be checked later)
#
# ## The mode is configuration, never code
#
# PRODUCTION when the leg's environment carries the production credentials,
# which reach CI as repository secrets (docs/release-signing.md, "Installer
# signing"):
#
#   .pkg  REPRO_PKG_SIGNING_P12_BASE64     the Developer ID Installer identity
#                                          (.p12, base64)
#         REPRO_PKG_SIGNING_P12_PASSWORD   its password
#         REPRO_NOTARY_API_KEY_P8          App Store Connect API key (.p8 text)
#         REPRO_NOTARY_API_KEY_ID          its key ID
#         REPRO_NOTARY_API_ISSUER_ID       its issuer ID
#   .msi  REPRO_AUTHENTICODE_PFX_BASE64    the Authenticode certificate (.pfx,
#                                          base64)
#         REPRO_AUTHENTICODE_PFX_PASSWORD  its password
#
# STAND-IN otherwise: make-test-installer-certs.sh generates the certificates
# in this run's scratch directory, REPRO_SIGNING_ALLOW_TEST_KEY=1 admits them,
# and notarization runs against stand-in-notary.sh. Setting the first variable
# of a set selects production; a partial set is refused, naming what is
# missing, rather than falling back to the stand-in.
#
# Both modes run the same steps below with the same scripts: the credential
# files, the notary command and the trust the signature is checked against are
# the only differences. A publishing run (REPRO_RELEASE_PUBLISHING=1, set by
# the release workflow on a tag) refuses the stand-in mode before it starts.
#
# Overrides (configuration, both modes): REPRO_NOTARYTOOL (default
# `/usr/bin/xcrun notarytool` in production, the stand-in otherwise),
# REPRO_STAPLER (`/usr/bin/xcrun stapler` / the stand-in), and the signing
# tools' variables documented in repro-sign-installer.sh. REPRO_NOTARYTOOL and
# REPRO_STAPLER are split on spaces into a command and its leading arguments.
#
# ## Notarization (.pkg)
#
# `<notarytool> submit <pkg> --key <p8> --key-id <id> --issuer <issuer> --wait
# --output-format json` (App Store Connect API key authentication:
# https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
# and `xcrun notarytool submit --help`). The leg passes only if the JSON
# answer's status is `Accepted`; otherwise it prints the submission's log
# (`notarytool log`) and fails. Then `<stapler> staple <pkg>`. On macOS,
# `spctl --assess --type install` must ACCEPT a production package and must
# REJECT a stand-in one (no Apple chain, no ticket): the rejection is the
# expected result and is asserted, not hidden. On macOS, xcrun and spctl are
# Apple's, run as /usr/bin/xcrun and /usr/sbin/spctl, never found on PATH.

set -eu

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
SIGN_DIR="$(CDPATH='' cd -- "$SELF_DIR/../release-signing" && pwd)"

log() { printf 'build-signed-installer: %s\n' "$*" >&2; }
die() { printf 'build-signed-installer: REFUSED: %s\n' "$*" >&2; exit 1; }

# Apple's tools are run by absolute path on macOS, never found on PATH: the
# release leg runs inside a Nix environment whose PATH lacks /usr/sbin, where
# spctl lives, and a PATH lookup would also let a program of the same name
# from that environment stand in for Apple's.
#
# `apple_tool <name>` sets APPLE_TOOL to the tool's path and returns 0. On
# macOS a tool that is not executable at its path is fatal, and the error
# names the path. Elsewhere the name is looked up on PATH, as it always was,
# and the call returns 1 when it is not there.
#
# REPRO_APPLE_TOOL_ROOT is for tests only (empty by default): a directory put
# in front of every path, which also selects the macOS lookup on any host. It
# swaps the notary client and the Gatekeeper assessment, so it is honoured
# only in STAND-IN mode outside a publishing run; in production mode the run
# dies, so no variable can replace the spctl that must accept the package.
apple_tool_root_check() {
  [ -n "${REPRO_APPLE_TOOL_ROOT:-}" ] || return 0
  if [ "${mode:-}" != standin ] || [ "${REPRO_RELEASE_PUBLISHING:-0}" = 1 ]; then
    die 'REPRO_APPLE_TOOL_ROOT is a test-only seam and is refused in production mode and in a publishing run; unset it'
  fi
}
apple_tool() {
  case "$1" in
    xcrun) APPLE_TOOL=/usr/bin/xcrun ;;
    spctl) APPLE_TOOL=/usr/sbin/spctl ;;
    *) die "internal: no path is recorded for the Apple tool '$1'" ;;
  esac
  apple_tool_root_check
  if [ -n "${REPRO_APPLE_TOOL_ROOT:-}" ] || [ "$(uname -s)" = Darwin ]; then
    APPLE_TOOL="${REPRO_APPLE_TOOL_ROOT:-}$APPLE_TOOL"
    [ -x "$APPLE_TOOL" ] || die "$1 not found at $APPLE_TOOL (macOS installs it there; PATH is not searched for it)"
  else
    APPLE_TOOL="$(command -v "$1" 2>/dev/null)" || return 1
  fi
}

ecosystem=''; out=''; version=''; archive=''; package=''; platform=''; asset_arch=''
while [ $# -gt 0 ]; do
  case "$1" in
    --ecosystem) ecosystem="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --archive) archive="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    --asset-arch) asset_arch="$2"; shift 2 ;;
    -h|--help) sed -n '2,62p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$ecosystem" in
  pkg) : "${platform:=darwin}" "${asset_arch:=aarch64}" ;;
  msi) : "${platform:=windows}" "${asset_arch:=x86_64}" ;;
  *) die "--ecosystem must be pkg or msi, not '$ecosystem'" ;;
esac
[ -n "$out" ] || die '--out is required'
if [ -n "$package" ]; then
  [ -s "$package" ] || die "--package $package is missing or empty"
  [ -z "$archive" ] || die 'pass --archive or --package, not both'
else
  [ -n "$version" ] && [ -n "$archive" ] || die 'pass --version and --archive (or --package)'
  [ -s "$archive" ] || die "--archive $archive is missing or empty"
fi
mkdir -p "$out"
out="$(CDPATH='' cd -- "$out" && pwd)"

umask 077
scratch="$(mktemp -d "${TMPDIR:-/tmp}/repro-installer-XXXXXX")"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT INT TERM

# ── Mode ─────────────────────────────────────────────────────────────
mode=standin
missing=''
need() { eval "_v=\${$1:-}"; [ -n "$_v" ] || missing="$missing $1"; }
if [ "$ecosystem" = pkg ]; then
  if [ -n "${REPRO_PKG_SIGNING_P12_BASE64:-}" ]; then
    mode=production
    for v in REPRO_PKG_SIGNING_P12_PASSWORD REPRO_NOTARY_API_KEY_P8 REPRO_NOTARY_API_KEY_ID REPRO_NOTARY_API_ISSUER_ID; do need "$v"; done
  fi
else
  if [ -n "${REPRO_AUTHENTICODE_PFX_BASE64:-}" ]; then
    mode=production
    need REPRO_AUTHENTICODE_PFX_PASSWORD
  fi
fi
[ -z "$missing" ] || die "production credentials are incomplete; missing:$missing (set them as repository secrets, docs/release-signing.md)"
if [ "$mode" = standin ] && [ "${REPRO_RELEASE_PUBLISHING:-0}" = 1 ]; then
  die "no production credentials for the $ecosystem and this is a publishing run (REPRO_RELEASE_PUBLISHING=1); a stand-in-signed $ecosystem is never published"
fi
log "mode: $mode"
apple_tool_root_check

creds="$scratch/credentials"
mkdir "$creds"
decode_b64() { printf '%s' "$1" | tr -d ' \r\n' | { base64 -d 2>/dev/null || base64 -D; } > "$2"; [ -s "$2" ] || die "$3 does not decode as base64"; }
trust_root=''
if [ "$mode" = production ]; then
  if [ "$ecosystem" = pkg ]; then
    identity="$creds/identity.p12"
    decode_b64 "$REPRO_PKG_SIGNING_P12_BASE64" "$identity" REPRO_PKG_SIGNING_P12_BASE64
    printf '%s' "$REPRO_PKG_SIGNING_P12_PASSWORD" > "$creds/identity.password"
    printf '%s\n' "$REPRO_NOTARY_API_KEY_P8" > "$creds/notary.p8"
    notary_key_id="$REPRO_NOTARY_API_KEY_ID"; notary_issuer="$REPRO_NOTARY_API_ISSUER_ID"
    xcrun=xcrun
    if [ -z "${REPRO_NOTARYTOOL:-}" ] || [ -z "${REPRO_STAPLER:-}" ]; then
      if apple_tool xcrun; then xcrun="$APPLE_TOOL"; fi
    fi
    notarytool="${REPRO_NOTARYTOOL:-$xcrun notarytool}"
    stapler="${REPRO_STAPLER:-$xcrun stapler}"
  else
    identity="$creds/identity.pfx"
    decode_b64 "$REPRO_AUTHENTICODE_PFX_BASE64" "$identity" REPRO_AUTHENTICODE_PFX_BASE64
    printf '%s' "$REPRO_AUTHENTICODE_PFX_PASSWORD" > "$creds/identity.password"
  fi
else
  sh "$SIGN_DIR/make-test-installer-certs.sh" --dir "$creds/standin"
  export REPRO_SIGNING_ALLOW_TEST_KEY=1
  if [ "$ecosystem" = pkg ]; then
    identity="$creds/standin/pkg-signer.p12"; cp "$creds/standin/pkg-signer.p12.password" "$creds/identity.password"
    trust_root="$creds/standin/pkg-root.pem"
    # A stand-in API key: a throwaway P-256 key in the .p8 (PKCS#8) form
    # App Store Connect issues, so the notary command line is built exactly
    # as in production.
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$creds/notary.p8" 2>/dev/null \
      || die 'cannot generate the stand-in notary key'
    notary_key_id='STANDIN000'; notary_issuer='00000000-0000-4000-8000-000000000001'
    notarytool="${REPRO_NOTARYTOOL:-sh $SIGN_DIR/stand-in-notary.sh notarytool}"
    stapler="${REPRO_STAPLER:-sh $SIGN_DIR/stand-in-notary.sh stapler}"
  else
    identity="$creds/standin/authenticode.pfx"; cp "$creds/standin/authenticode.pfx.password" "$creds/identity.password"
    trust_root="$creds/standin/authenticode.pem"
  fi
fi

# spctl is resolved before anything is built, so that on macOS a missing one
# refuses the run before it leaves an unassessed package behind.
spctl=''
if [ "$ecosystem" = pkg ] && apple_tool spctl; then spctl="$APPLE_TOOL"; fi

# ── Build ────────────────────────────────────────────────────────────
if [ -n "$package" ]; then
  unsigned="$package"
  asset="$(basename -- "$package")"
else
  sh "$SELF_DIR/repro-build-packages.sh" --version "$version" --tarball "$archive" \
    --out "$scratch/build" --ecosystem "$ecosystem" --platform "$platform" --asset-arch "$asset_arch"
  asset="reprobuild-${version}-${platform}-${asset_arch}.${ecosystem}"
  unsigned="$scratch/build/$asset"
  [ -s "$unsigned" ] || die "repro-build-packages.sh did not produce $asset"
fi
case "$asset" in *".$ecosystem") ;; *) die "$asset is not a .$ecosystem" ;; esac
signed="$out/$asset"
report="$out/$asset.signing-report.txt"
rm -f "$signed" "$signed.sha256" "$report" "$signed.SIGNED-WITH-A-TEST-CERTIFICATE" "$signed.stand-in-root.pem"
{
  printf 'asset: %s\n' "$asset"
  printf 'mode: %s\n' "$mode"
  printf 'publishing run: %s\n' "${REPRO_RELEASE_PUBLISHING:-0}"
} > "$report"

# ── Sign and verify ──────────────────────────────────────────────────
set -- --kind "$ecosystem" --in "$unsigned" --out "$signed" \
  --identity "$identity" --password-file "$creds/identity.password" --scratch "$scratch"
[ -z "$trust_root" ] || set -- "$@" --trust-root "$trust_root"
result="$(sh "$SIGN_DIR/repro-sign-installer.sh" "$@")" || die "signing the $asset failed"
printf 'signing: %s\n' "$result" >> "$report"
case "$mode:$result" in
  production:class=test*) rm -f "$signed" "$signed.SIGNED-WITH-A-TEST-CERTIFICATE"
    die "the production credential is a TEST certificate (it carries the stand-in marker); refusing" ;;
  standin:class=platform*) rm -f "$signed"; die 'internal: the stand-in certificate was not classified as a test certificate' ;;
esac

# ── Notarize, staple, assess (.pkg) ──────────────────────────────────
if [ "$ecosystem" = pkg ]; then
  # shellcheck disable=SC2086 # the command strings are split on purpose
  set -- $notarytool
  "$@" submit "$signed" --key "$creds/notary.p8" --key-id "$notary_key_id" \
    --issuer "$notary_issuer" --wait --output-format json > "$scratch/notary.json" 2>"$scratch/notary.err" \
    || { cat "$scratch/notary.err" >&2; die "the notary command failed: $notarytool submit"; }
  answer="$(tr -d '\n' < "$scratch/notary.json")"
  status="$(printf '%s' "$answer" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  sub_id="$(printf '%s' "$answer" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  case "$answer" in *'"standIn"'*) notary_kind=stand-in ;; *) notary_kind=service ;; esac
  printf 'notarization: %s (%s), status %s, submission %s\n' "$notarytool" "$notary_kind" "${status:-<none>}" "${sub_id:-<none>}" >> "$report"
  if [ "$mode" = production ] && [ "$notary_kind" = stand-in ]; then
    rm -f "$signed"; die 'production mode was answered by the stand-in notary; REPRO_NOTARYTOOL must name the real notarytool'
  fi
  if [ "$status" != Accepted ]; then
    if [ -n "$sub_id" ]; then
      "$@" log "$sub_id" --key "$creds/notary.p8" --key-id "$notary_key_id" --issuer "$notary_issuer" >&2 || true
    fi
    rm -f "$signed" "$signed.SIGNED-WITH-A-TEST-CERTIFICATE"
    die "notarization of $asset ended with status '${status:-<none>}', not Accepted (answer: $answer)"
  fi
  # shellcheck disable=SC2086
  set -- $stapler
  "$@" staple "$signed" >"$scratch/staple.log" 2>&1 \
    || { cat "$scratch/staple.log" >&2; rm -f "$signed"; die 'stapling the notarization ticket failed'; }
  printf 'stapled: yes (%s)\n' "$notary_kind" >> "$report"
  if [ -n "$spctl" ]; then
    if "$spctl" --assess --type install -vv "$signed" >"$scratch/spctl.log" 2>&1; then spctl_ok=1; else spctl_ok=0; fi
    cat "$scratch/spctl.log" >&2
    if [ "$mode" = production ]; then
      [ "$spctl_ok" = 1 ] || { rm -f "$signed"; die 'spctl --assess --type install rejects the notarized package'; }
      printf 'gatekeeper: accepted (spctl --assess --type install)\n' >> "$report"
    else
      [ "$spctl_ok" = 0 ] || { rm -f "$signed"; die 'spctl ACCEPTED a stand-in-signed package; something on this machine trusts the stand-in root'; }
      printf 'gatekeeper: rejected, as a stand-in must be (spctl --assess --type install)\n' >> "$report"
    fi
  else
    printf 'gatekeeper: not assessed (no spctl on this host)\n' >> "$report"
  fi
fi

# ── Outputs ──────────────────────────────────────────────────────────
if command -v sha256sum >/dev/null 2>&1; then digest="$(sha256sum -b < "$signed")"; else digest="$(shasum -a 256 -b < "$signed")"; fi
digest="${digest%% *}"
printf '%s  %s\n' "$digest" "$asset" > "$signed.sha256"
if [ "$mode" = standin ]; then
  [ -f "$signed.SIGNED-WITH-A-TEST-CERTIFICATE" ] || die 'internal: the stand-in signature left no marker'
  cp "$trust_root" "$signed.stand-in-root.pem"
fi
printf 'sha256: %s\n' "$digest" >> "$report"
cat "$report" >&2
log "done: $signed ($mode)"
