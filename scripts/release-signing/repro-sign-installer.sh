#!/bin/sh
# Sign a macOS installer package (.pkg) or a Windows Installer package (.msi),
# and verify the signature it made.
#
#   repro-sign-installer.sh --kind pkg|msi --in <unsigned> --out <signed> \
#       --identity <file.p12|file.pfx> --password-file <file> \
#       [--trust-root <root.pem>] [--scratch <dir>]
#
# ONE code path for the stand-in certificates and the production ones: what
# differs is the certificate it is handed, and the certificate alone decides
# how it is treated, exactly as lib-signing.sh treats OpenPGP keys
# (docs/release-signing.md, "Key classification"):
#
#   test      the signer certificate's subject carries the marker
#             O=REPROBUILD UNTRUSTED TEST CERTIFICATE (make-test-installer-certs.sh).
#             Signed with only when REPRO_SIGNING_ALLOW_TEST_KEY=1, never when
#             REPRO_RELEASE_PUBLISHING=1, and verified against --trust-root,
#             which is then required. The output gets a marker file,
#             <out>.SIGNED-WITH-A-TEST-CERTIFICATE, beside it.
#   platform  any other certificate. Signed with, then verified against the
#             PLATFORM's trust -- Apple's chain on macOS (pkgutil), Windows'
#             own trust (Get-AuthenticodeSignature `Valid`) -- or, off those
#             platforms, against an explicitly configured root
#             (REPRO_PKG_TRUST_ROOT, REPRO_AUTHENTICODE_TRUST_BUNDLE). A
#             certificate no platform trusts therefore signs and is then
#             refused; there is no committed allowlist to edit, because
#             swapping in the production certificate must be configuration
#             only (CI secrets), with no change to this repository.
#
# The identity is a PKCS#12 container (the .p12 a Developer ID Installer
# certificate is exported as from Keychain Access; the .pfx an Authenticode
# certificate is delivered as) and the file holding its password.
#
# ## Signing tools
#
# .pkg  REPRO_PKG_SIGN_TOOL=productsign (the default on macOS, where it is
#       /usr/bin/productsign) imports the identity into a keychain made for
#       this run under --scratch -- never the login keychain, never added to
#       the keychain search list -- signs with
#       `productsign --sign <SHA-1> --keychain <it>`, and deletes it.
#       REPRO_PKG_SIGN_TOOL=rcodesign (the default elsewhere) signs with
#       apple-codesign (https://gregoryszorc.com/docs/apple-codesign/main/),
#       which writes the same XAR signatures on any OS; its PEM input (key,
#       signer, chain) exists in --scratch only while it signs.
#       A platform certificate is signed with a secure timestamp (Apple's
#       service, the tools' default; REPRO_PKG_TIMESTAMP_URL names another
#       server for rcodesign, and `none` turns it off), a test certificate
#       without one.
# .msi  REPRO_AUTHENTICODE_TOOL=signtool (the default where REPRO_SIGNTOOL
#       names it or signtool.exe is on PATH) signs with
#       `signtool sign /fd sha256 /f <pfx> /p <password>`; =osslsigncode (the
#       default elsewhere) with `osslsigncode sign -pkcs12 <pfx> -readpass`.
#       A platform certificate is timestamped by the RFC 3161 server
#       REPRO_AUTHENTICODE_TIMESTAMP_URL (default http://timestamp.digicert.com;
#       `none` turns it off), a test certificate is not.
#
# ## Verification, after signing (the step fails unless it passes)
#
# .pkg  verify-xar-signature.py against --trust-root (test) or
#       REPRO_PKG_TRUST_ROOT (platform, off macOS); on macOS also
#       `pkgutil --check-signature`, which must name the signer and, for a
#       platform certificate, report it "signed by a developer certificate
#       issued by Apple for distribution".
# .msi  `osslsigncode verify -CAfile <root>` where osslsigncode exists, and on
#       Windows verify-authenticode.ps1 (the signer's thumbprint and an intact
#       signature for a test certificate; `Valid` for a platform one). At
#       least one verifier must run.
#
# Prints `class=<test|platform> tool=<tool> signer=<subject> sha256=<fpr>` on
# stdout when it succeeds. Exit 1 on any refusal, with the reason on stderr.

set -eu

SI_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
SI_MARKER='REPROBUILD UNTRUSTED TEST CERTIFICATE'
SI_MARKER_SUFFIX='.SIGNED-WITH-A-TEST-CERTIFICATE'

log() { printf 'repro-sign-installer: %s\n' "$*" >&2; }
die() { printf 'repro-sign-installer: REFUSED: %s\n' "$*" >&2; exit 1; }

# Apple's tools are run by absolute path on macOS, never found on PATH: the
# release leg runs inside a Nix environment whose PATH lacks /usr/sbin, where
# pkgutil lives, and a PATH lookup would also let a program of the same name
# from that environment stand in for Apple's.
#
# `apple_tool <name>` sets APPLE_TOOL to the tool's path and returns 0. On
# macOS a tool that is not executable at its path is fatal, and the error
# names the path. Elsewhere the name is looked up on PATH, as it always was,
# and the call returns 1 when it is not there.
#
# REPRO_APPLE_TOOL_ROOT is for tests only (empty by default): a directory put
# in front of every path, which also selects the macOS lookup on any host. It
# swaps the signer and the verifier, so it is honoured only for a TEST
# certificate (which is itself refused in a publishing run and needs
# REPRO_SIGNING_ALLOW_TEST_KEY=1); with any other certificate the run dies,
# so no variable can replace the pkgutil that checks a platform signature.
apple_tool_root_check() {
  [ -n "${REPRO_APPLE_TOOL_ROOT:-}" ] || return 0
  [ "${class:-}" = test ] \
    || die 'REPRO_APPLE_TOOL_ROOT is a test-only seam and is refused unless the signer certificate is a TEST certificate; unset it'
}
apple_tool() {
  case "$1" in
    productsign) APPLE_TOOL=/usr/bin/productsign ;;
    security)    APPLE_TOOL=/usr/bin/security ;;
    pkgutil)     APPLE_TOOL=/usr/sbin/pkgutil ;;
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

kind=''; in=''; out=''; identity=''; password_file=''; trust_root=''; scratch=''
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) kind="$2"; shift 2 ;;
    --in) in="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --identity) identity="$2"; shift 2 ;;
    --password-file) password_file="$2"; shift 2 ;;
    --trust-root) trust_root="$2"; shift 2 ;;
    --scratch) scratch="$2"; shift 2 ;;
    -h|--help) sed -n '2,72p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$kind" in pkg|msi) ;; *) die "--kind must be pkg or msi, not '$kind'" ;; esac
[ -n "$in" ] && [ -s "$in" ] || die "--in '$in' is missing or empty"
[ -n "$out" ] || die '--out is required'
[ -n "$identity" ] && [ -s "$identity" ] || die "--identity '$identity' is missing or empty"
[ -n "$password_file" ] && [ -f "$password_file" ] || die "--password-file '$password_file' does not exist"
[ -z "$trust_root" ] || [ -s "$trust_root" ] || die "--trust-root $trust_root does not exist"
command -v openssl >/dev/null 2>&1 || die 'openssl is not on PATH'

own_scratch=0
if [ -z "$scratch" ]; then
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/repro-sign-installer-XXXXXX")"
  own_scratch=1
fi
umask 077
work="$scratch/sign-$$"
mkdir -p "$work"
keychain=''; security=''
cleanup() {
  if [ -n "$keychain" ]; then "$security" delete-keychain "$keychain" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
  if [ "$own_scratch" -eq 1 ]; then rm -rf "$scratch"; fi
}
trap cleanup EXIT INT TERM

# ── The identity's certificates ──────────────────────────────────────
# A keychain export may use RC2 for its certificate bag, which OpenSSL 3 reads
# only with its legacy provider, so `-legacy` is the fallback.
# The password is read from stdin, never from the command line, and not
# through `file:`, which Git for Windows' native openssl would be handed as an
# unconverted MSYS path.
p12() {
  openssl pkcs12 -in "$identity" -passin stdin "$@" <"$password_file" 2>"$work/p12.err" \
    || openssl pkcs12 -legacy -in "$identity" -passin stdin "$@" <"$password_file" 2>>"$work/p12.err"
}
p12 -clcerts -nokeys -out "$work/signer.pem" \
  || { cat "$work/p12.err" >&2; die "cannot open $identity with the given password"; }
grep -q 'BEGIN CERTIFICATE' "$work/signer.pem" || die "$identity holds no certificate paired with its key"
p12 -cacerts -nokeys -out "$work/chain.pem" || : > "$work/chain.pem"
subject="$(openssl x509 -in "$work/signer.pem" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
sha256="$(openssl x509 -in "$work/signer.pem" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
sha1="$(openssl x509 -in "$work/signer.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"

# ── Classification and policy ────────────────────────────────────────
case "$subject" in
  *"$SI_MARKER"*) class='test' ;;
  *) class=platform ;;
esac
if [ "$class" = test ]; then
  [ "${REPRO_RELEASE_PUBLISHING:-0}" != 1 ] \
    || die "the signer certificate is a TEST certificate ($subject) and this is a publishing run (REPRO_RELEASE_PUBLISHING=1); a stand-in-signed $kind is never published"
  [ "${REPRO_SIGNING_ALLOW_TEST_KEY:-0}" = 1 ] \
    || die "the signer certificate is a TEST certificate ($subject) and REPRO_SIGNING_ALLOW_TEST_KEY is not 1; refusing to sign"
  [ -n "$trust_root" ] || die "a TEST certificate is verified against its stand-in root; pass --trust-root"
  log "signing with a TEST certificate ($subject); the output will carry $(basename "$out")$SI_MARKER_SUFFIX"
else
  log "signing with $subject (sha256 $sha256); it must verify against the platform's trust"
fi
apple_tool_root_check

out_dir="$(dirname -- "$out")"
mkdir -p "$out_dir"
rm -f "$out" "$out$SI_MARKER_SUFFIX"
on_windows() { [ -n "${SYSTEMROOT:-}" ] && command -v cygpath >/dev/null 2>&1; }
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi; }

# pkgutil is resolved before anything is signed, so that on macOS a missing
# one refuses the run before it leaves an unverified package behind.
pkgutil=''
if [ "$kind" = pkg ] && apple_tool pkgutil; then pkgutil="$APPLE_TOOL"; fi

# ── Sign ─────────────────────────────────────────────────────────────
if [ "$kind" = pkg ]; then
  tool="${REPRO_PKG_SIGN_TOOL:-}"
  if [ -z "$tool" ]; then
    if apple_tool productsign; then tool=productsign; else tool=rcodesign; fi
  fi
  case "$tool" in
    productsign)
      apple_tool productsign || die 'productsign not found (macOS)'
      productsign="$APPLE_TOOL"
      apple_tool security || die 'productsign needs the `security` tool (macOS)'
      security="$APPLE_TOOL"
      keychain="$work/signing.keychain-db"
      kc_pass="$(openssl rand -hex 24)"
      "$security" create-keychain -p "$kc_pass" "$keychain" >/dev/null \
        || die "cannot create the run's keychain at $keychain"
      "$security" set-keychain-settings "$keychain" >/dev/null
      "$security" unlock-keychain -p "$kc_pass" "$keychain" >/dev/null
      "$security" import "$identity" -k "$keychain" -f pkcs12 -P "$(cat "$password_file")" \
        -T "$productsign" >/dev/null \
        || die "cannot import $identity into the run's keychain"
      # Lets productsign use the key without a confirmation dialog.
      "$security" set-key-partition-list -S apple-tool:,apple: -s -k "$kc_pass" "$keychain" >/dev/null 2>&1 || true
      if [ "$class" = test ] || [ "${REPRO_PKG_TIMESTAMP_URL:-}" = none ]; then ts='--timestamp=none'; else ts='--timestamp'; fi
      "$productsign" --sign "$sha1" --keychain "$keychain" "$ts" "$in" "$out" >"$work/sign.log" 2>&1 \
        || { cat "$work/sign.log" >&2; die 'productsign failed'; }
      ;;
    rcodesign)
      command -v rcodesign >/dev/null 2>&1 || die 'rcodesign (apple-codesign) is not on PATH'
      # rcodesign pairs the key with the FIRST certificate it reads, and in a
      # .p12 that may be an intermediate; a PEM bundle of key, signer, chain
      # (in that order) is unambiguous.
      p12 -nocerts -nodes -out "$work/signing.pem" || die "cannot read the key from $identity"
      cat "$work/signer.pem" "$work/chain.pem" >> "$work/signing.pem"
      cp "$in" "$out"
      if [ "$class" = test ]; then ts=none; else ts="${REPRO_PKG_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"; fi
      rcodesign sign --pem-file "$work/signing.pem" --timestamp-url "$ts" "$out" >"$work/sign.log" 2>&1 \
        || { rm -f "$work/signing.pem"; cat "$work/sign.log" >&2; die 'rcodesign sign failed'; }
      rm -f "$work/signing.pem"
      ;;
    *) die "unknown REPRO_PKG_SIGN_TOOL '$tool' (productsign or rcodesign)" ;;
  esac
else
  tool="${REPRO_AUTHENTICODE_TOOL:-}"
  if [ -z "$tool" ]; then
    if [ -n "${REPRO_SIGNTOOL:-}" ] || command -v signtool.exe >/dev/null 2>&1; then tool=signtool; else tool=osslsigncode; fi
  fi
  ts_url=''
  [ "$class" = test ] || ts_url="${REPRO_AUTHENTICODE_TIMESTAMP_URL:-http://timestamp.digicert.com}"
  [ "$ts_url" != none ] || ts_url=''
  case "$tool" in
    signtool)
      st="${REPRO_SIGNTOOL:-signtool.exe}"
      if command -v cygpath >/dev/null 2>&1; then st="$(cygpath -u "$st")"; fi
      command -v "$st" >/dev/null 2>&1 || [ -x "$st" ] || die "signtool not found ($st); set REPRO_SIGNTOOL"
      cp "$in" "$out"
      # MSYS2 rewrites arguments that look like POSIX paths, and every
      # signtool switch starts with '/'; turn that off for this call.
      if [ -n "$ts_url" ]; then
        MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 "$st" sign /fd sha256 /f "$(winpath "$identity")" \
          /p "$(cat "$password_file")" /d Reprobuild /tr "$ts_url" /td sha256 "$(winpath "$out")" >"$work/sign.log" 2>&1 \
          || { cat "$work/sign.log" >&2; die 'signtool sign failed'; }
      else
        MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 "$st" sign /fd sha256 /f "$(winpath "$identity")" \
          /p "$(cat "$password_file")" /d Reprobuild "$(winpath "$out")" >"$work/sign.log" 2>&1 \
          || { cat "$work/sign.log" >&2; die 'signtool sign failed'; }
      fi
      ;;
    osslsigncode)
      command -v osslsigncode >/dev/null 2>&1 || die 'osslsigncode is not on PATH'
      set -- sign -pkcs12 "$identity" -readpass "$password_file" -h sha256 -n Reprobuild
      [ -z "$ts_url" ] || set -- "$@" -ts "$ts_url"
      osslsigncode "$@" -in "$in" -out "$out" >"$work/sign.log" 2>&1 \
        || { cat "$work/sign.log" >&2; die 'osslsigncode sign failed'; }
      ;;
    *) die "unknown REPRO_AUTHENTICODE_TOOL '$tool' (signtool or osslsigncode)" ;;
  esac
fi
[ -s "$out" ] || die "signing produced no $out"

# ── Verify ───────────────────────────────────────────────────────────
verified=0
fail_verify() { rm -f "$out"; die "$*"; }
if [ "$kind" = pkg ]; then
  root="$trust_root"
  [ "$class" = test ] || root="${REPRO_PKG_TRUST_ROOT:-}"
  if [ -n "$root" ]; then
    python3 "$SI_DIR/verify-xar-signature.py" "$out" --trust-root "$root" >"$work/verify.log" 2>&1 \
      || { cat "$work/verify.log" >&2; fail_verify "the signed package does not verify against $root"; }
    cat "$work/verify.log" >&2
    verified=$((verified + 1))
  fi
  if [ -n "$pkgutil" ]; then
    "$pkgutil" --check-signature "$out" >"$work/pkgutil.log" 2>&1 || true
    cat "$work/pkgutil.log" >&2
    signer_cn="$(openssl x509 -in "$work/signer.pem" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p' | head -1)"
    grep -qF -- "$signer_cn" "$work/pkgutil.log" \
      || fail_verify "pkgutil --check-signature does not name the signer '$signer_cn'"
    if [ "$class" = platform ]; then
      grep -q 'signed by a developer certificate issued by Apple for distribution' "$work/pkgutil.log" \
        || fail_verify 'pkgutil does not report the package signed by a developer certificate issued by Apple for distribution'
    fi
    verified=$((verified + 1))
  fi
  [ "$verified" -gt 0 ] \
    || fail_verify "no verifier could run: a platform-signed .pkg is verified by pkgutil (macOS) or against REPRO_PKG_TRUST_ROOT"
else
  if command -v osslsigncode >/dev/null 2>&1; then
    if [ "$class" = test ]; then bundle="$trust_root"; else bundle="${REPRO_AUTHENTICODE_TRUST_BUNDLE:-}"; fi
    set -- verify -in "$out"
    [ -z "$bundle" ] || set -- "$@" -CAfile "$bundle"
    if osslsigncode "$@" >"$work/verify.log" 2>&1 && grep -q 'Signature verification: ok' "$work/verify.log"; then
      grep -E 'Subject|Signature verification|Number of verified' "$work/verify.log" >&2 || true
      verified=$((verified + 1))
    else
      tail -n 20 "$work/verify.log" >&2
      fail_verify "osslsigncode does not verify the signed MSI against ${bundle:-its default CA bundle}"
    fi
  fi
  if on_windows && command -v powershell.exe >/dev/null 2>&1; then
    if [ "$class" = test ]; then
      set -- -StandInCertificate "$(winpath "$trust_root")"
    else
      set -- -RequireValid
    fi
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$SI_DIR/verify-authenticode.ps1")" \
      -Path "$(winpath "$out")" "$@" >"$work/verify-ps.log" 2>&1 \
      || { cat "$work/verify-ps.log" >&2; fail_verify 'verify-authenticode.ps1 refused the signed MSI'; }
    cat "$work/verify-ps.log" >&2
    verified=$((verified + 1))
  fi
  [ "$verified" -gt 0 ] || fail_verify 'no verifier could run: osslsigncode or Windows PowerShell is required'
fi

if [ "$class" = test ]; then
  {
    printf 'This file was signed with a STAND-IN (test) certificate, generated for\n'
    printf 'one run by scripts/release-signing/make-test-installer-certs.sh:\n'
    printf '  %s\n  sha256 %s\n' "$subject" "$sha256"
    printf 'No platform trusts it. It is never published: a publishing run refuses\n'
    printf 'to sign with it, and the release refuses any asset beside this marker.\n'
  } > "$out$SI_MARKER_SUFFIX"
fi
printf 'class=%s tool=%s signer=%s sha256=%s\n' "$class" "$tool" "$subject" "$sha256"
