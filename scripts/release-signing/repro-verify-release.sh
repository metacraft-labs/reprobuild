#!/bin/sh
# The installer's PRE-INSTALL verification. Clause (b) of the M2 gate.
#
#   repro-verify-release.sh --keyring <file|dir> --dir <download-dir>
#                           [--artifact <name>]... [--allow-test-key]
#                           [--require-all]
#
# Exit 0  — every requested artifact is covered by a signed manifest
#           whose signature was made by a key in <keyring>, its bytes
#           hash to the manifest's digest, and its own detached
#           signature verifies.
# Exit 1  — anything else. There is no "could not check, proceeding".
#
# ## Contract for M3's installer
#
# M3 owns the installer; M2 owns this. The installer calls:
#
#   "$dir/repro-verify-release.sh" --keyring "$keyring" --dir "$tmp" \
#       --artifact "reprobuild-x86_64-linux.tar.gz" \
#     || fail "signature verification failed; refusing to install"
#
# BEFORE it unpacks or executes anything it downloaded. This script
# depends on nothing but a POSIX shell, `sha256sum` (or macOS's `shasum`) and `gpgv` (or
# `gpg`) — deliberately, because a verifier that needs the payload it is
# verifying has verified nothing.
#
# ## Why it has no fallback
#
# apps/repro-harvest-{apt,dnf}/src/*/signature.nim degrade to a BLAKE3
# allowlist when gpg is absent. That is right for a harvester pinned to
# a frozen upstream snapshot. It is wrong here. An installer that
# proceeds because it could not find gpg is an installer with no
# security property at all, and "the check passed because the check did
# not run" is the exact false green this milestone's gate forbids. So:
# no gpg, no install. No signature file, no install. No manifest line
# for the artifact, no install.

set -eu

RV_TEST_KEY_MARKER='REPROBUILD UNTRUSTED TEST KEY'
RV_TEST_MARKER_FILE='SIGNING-KEY-IS-A-TEST-KEY'
RV_SUMS='SHA256SUMS'
RV_SUMS_SIG='SHA256SUMS.asc'

rv_log()  { printf 'repro-verify: %s\n' "$*" >&2; }
rv_fail() { printf 'repro-verify: REJECTED: %s\n' "$*" >&2; exit 1; }

keyring=''
dir=''
artifacts=''
allow_test_key=0
require_all=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keyring) keyring="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --artifact) artifacts="$artifacts $2"; shift 2 ;;
    --allow-test-key) allow_test_key=1; shift ;;
    --require-all) require_all=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) rv_fail "unknown argument: $1" ;;
  esac
done

[ -n "$keyring" ] || rv_fail '--keyring is required'
[ -n "$dir" ]     || rv_fail '--dir is required'
[ -d "$dir" ]     || rv_fail "--dir $dir is not a directory"

# ── 0. The tools must exist. Missing tools are a REJECTION. ──────────

if [ -n "${REPRO_GPG_BIN:-}" ]; then
  GPG="$REPRO_GPG_BIN"
elif command -v gpg >/dev/null 2>&1; then
  GPG="$(command -v gpg)"
elif command -v gpg2 >/dev/null 2>&1; then
  GPG="$(command -v gpg2)"
else
  rv_fail 'no gpg/gpg2 on PATH and $REPRO_GPG_BIN unset. Refusing to install unverified bytes.'
fi
# `sha256sum` where there is one; macOS ships `shasum` instead. Both print
# "<digest> <mode><name>". The file is read from STDIN, in binary mode, so the
# digest is always the first field: given a path holding a backslash -- every
# Windows path the PowerShell installer passes as --dir -- GNU sha256sum
# escapes the line by starting it with a backslash (see the manual cited in
# step 4), which would put a '\' in front of the digest. `-b` makes the read
# byte-exact where text and binary differ (MSYS2, Cygwin) and changes nothing
# elsewhere.
if command -v sha256sum >/dev/null 2>&1; then
  rv_sha256() { sha256sum -b < "$1"; }
elif command -v shasum >/dev/null 2>&1; then
  rv_sha256() { shasum -a 256 -b < "$1"; }
else
  rv_fail 'no sha256sum or shasum on PATH. Refusing to install unverified bytes.'
fi

# ── 1. Ephemeral keyring. ────────────────────────────────────────────
#
# gpg is stateful. Verifying against ~/.gnupg would pass for any key the
# operator already trusts, INCLUDING when the release key was never
# imported — the test would then be measuring the operator's keyring.
# Every run starts from an empty home.

GNUPGHOME="$(mktemp -d "${TMPDIR:-/tmp}/repro-verify-gnupg-XXXXXX")"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
cleanup() {
  gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
  rm -rf "$GNUPGHOME"
}
trap cleanup EXIT INT TERM

gpg_q() { "$GPG" --batch --no-tty --quiet --keyid-format long "$@"; }

imported=0
import_one() {
  f="$1"
  if gpg_q --import "$f" >/dev/null 2>&1; then
    imported=$((imported + 1))
  else
    rv_log "warning: could not import key material from $f"
  fi
}

if [ -d "$keyring" ]; then
  for f in "$keyring"/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.gpg|*.asc|*.key|*.pub) import_one "$f" ;;
    esac
  done
elif [ -f "$keyring" ]; then
  import_one "$keyring"
else
  rv_fail "--keyring $keyring is neither a file nor a directory"
fi

[ "$imported" -gt 0 ] \
  || rv_fail "no OpenPGP keys imported from $keyring; there is nothing to verify against"

key_count="$("$GPG" --batch --with-colons --list-keys 2>/dev/null | grep -c '^pub:' || true)"
[ "$key_count" -gt 0 ] \
  || rv_fail "keyring $keyring imported but holds zero public keys"
rv_log "trust anchor: $key_count key(s) from $keyring"

# ── 2. Test keys must be declared. ───────────────────────────────────

if "$GPG" --batch --with-colons --list-keys 2>/dev/null \
     | awk -F: '$1=="uid" {print $10}' | grep -qF "$RV_TEST_KEY_MARKER"; then
  if [ "$allow_test_key" -ne 1 ]; then
    rv_fail "the keyring contains a key marked '$RV_TEST_KEY_MARKER' and --allow-test-key was not given. A test key never verifies a release."
  fi
  rv_log "NOTE: verifying against a TEST key (--allow-test-key)."
fi

if [ -f "$dir/$RV_TEST_MARKER_FILE" ] && [ "$allow_test_key" -ne 1 ]; then
  rv_fail "$dir carries $RV_TEST_MARKER_FILE: it was signed by a throwaway test key and is not a release."
fi

# ── 3. The manifest signature. ───────────────────────────────────────

[ -f "$dir/$RV_SUMS" ] \
  || rv_fail "$RV_SUMS missing from $dir"
[ -f "$dir/$RV_SUMS_SIG" ] \
  || rv_fail "$RV_SUMS_SIG missing from $dir; an unsigned manifest is not evidence of anything"

status_file="$GNUPGHOME/status.txt"
set +e
"$GPG" --batch --no-tty --keyid-format long \
  --status-file "$status_file" \
  --verify "$dir/$RV_SUMS_SIG" "$dir/$RV_SUMS" >"$GNUPGHOME/verify.log" 2>&1
verify_rc=$?
set -e
if [ "$verify_rc" -ne 0 ]; then
  rv_log "--- gpg --verify output ---"
  cat "$GNUPGHOME/verify.log" >&2 || true
  rv_log "--- end gpg output ---"
  rv_fail "the signature on $RV_SUMS is not valid under $keyring (gpg exit $verify_rc)"
fi
# gpg can exit 0 on a signature it considers valid-but-untrusted; the
# machine-readable status is the thing to assert on, not the exit code.
grep -q '^\[GNUPG:\] VALIDSIG ' "$status_file" \
  || { cat "$GNUPGHOME/verify.log" >&2 || true;
       rv_fail "gpg exited 0 but emitted no VALIDSIG for $RV_SUMS"; }
signer="$(awk '/^\[GNUPG:\] VALIDSIG /{print $3; exit}' "$status_file")"
rv_log "$RV_SUMS signature OK, signer $signer"

# ── 4. Which artifacts? ──────────────────────────────────────────────
#
# A manifest line is what GNU `sha256sum` writes and `sha256sum -c` reads
# (https://www.gnu.org/software/coreutils/manual/html_node/md5sum-invocation.html,
# which sha256sum-invocation refers to): the 64 hex digits of the digest, one
# space, a mode character, and the file name to the end of the line. The mode
# character is a space for text mode (`<hex>  <name>`) and `*` for binary
# mode (`<hex> *<name>`). It describes how the file was read, not the name:
# MSYS2's and Cygwin's sha256sum write `*` by default, so a manifest made on
# Windows carries it, and `sha256sum -c` accepts both forms. So does this
# parser, and nothing looser: the name must equal the artifact exactly (no
# prefix, suffix or whitespace folding), and a line of any other shape --
# a short or non-hex digest, a missing mode character, an escaped name
# (`\` first, which sha256sum writes for a name holding a newline or a
# backslash) or BSD's `SHA256 (<name>) = <hex>` -- matches nothing.
#
# The awk program is POSIX (no interval expressions, which mawk and older
# busybox builds lack). It prints "<lower-case digest> <name>" for every
# well-formed line and "MALFORMED <line number>" for any other non-empty one.
rv_parse_sums() {
  awk '
    {
      line = $0
      if (line == "") next
      digest = substr(line, 1, 64)
      mode = substr(line, 66, 1)
      name = substr(line, 67)
      if (length(line) < 67 || length(digest) != 64 ||
          digest !~ /^[0-9A-Fa-f]+$/ || substr(line, 65, 1) != " " ||
          (mode != " " && mode != "*") || name == "") {
        print "MALFORMED " NR
        next
      }
      print tolower(digest) " " name
    }
  ' "$1"
}
parsed_sums="$GNUPGHOME/sums.parsed"
rv_parse_sums "$dir/$RV_SUMS" > "$parsed_sums"

if [ -z "$artifacts" ] || [ "$require_all" -eq 1 ]; then
  # Every line is to be checked, so a line that is not a manifest line is a
  # rejection: it would otherwise be a signed entry nobody looked at.
  bad="$(awk '$1 == "MALFORMED" { print $2; exit }' "$parsed_sums")"
  [ -z "$bad" ] \
    || rv_fail "line $bad of the signed $RV_SUMS is not a sha256sum line (<64 hex digits>, a space, ' ' or '*', a name)"
  artifacts="$(awk '$1 != "MALFORMED" { sub(/^[^ ]+ /, ""); print }' "$parsed_sums")"
fi

n_checked=0
for a in $artifacts; do
  [ -n "$a" ] || continue

  # The artifact is read as "$dir/$a". A name that leaves the download
  # directory, or names it, is not an artifact of this release.
  case "$a" in
    */*|*\\*|.|..) rv_fail "$a is not a plain file name; refusing to look outside $dir" ;;
  esac

  # 4a. the manifest must MENTION it. A missing line is a rejection,
  #     never a skip -- otherwise an attacker deletes the line.
  line="$(awk -v want="$a" '$1 != "MALFORMED" { d = $1; sub(/^[^ ]+ /, ""); if ($0 == want) print d }' "$parsed_sums")"
  [ -n "$line" ] \
    || rv_fail "$a has no entry in the signed $RV_SUMS"
  hits="$(printf '%s\n' "$line" | grep -c .)"
  [ "$hits" -eq 1 ] \
    || rv_fail "$a appears $hits times in $RV_SUMS; a manifest with duplicate entries is ambiguous"

  # 4b. the bytes must be present and hash to it.
  [ -f "$dir/$a" ] || rv_fail "$a is listed in $RV_SUMS but not present in $dir"
  actual="$(rv_sha256 "$dir/$a" | awk '{print $1}')"
  if [ "$actual" != "$line" ]; then
    rv_fail "$a digest mismatch: signed manifest says $line, downloaded bytes are $actual"
  fi

  # 4c. and its own detached signature must verify.
  if [ -f "$dir/$a.asc" ]; then
    set +e
    "$GPG" --batch --no-tty --keyid-format long \
      --status-file "$GNUPGHOME/status-$n_checked.txt" \
      --verify "$dir/$a.asc" "$dir/$a" >"$GNUPGHOME/verify-$n_checked.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      cat "$GNUPGHOME/verify-$n_checked.log" >&2 || true
      rv_fail "detached signature $a.asc does not verify (gpg exit $rc)"
    fi
    grep -q '^\[GNUPG:\] VALIDSIG ' "$GNUPGHOME/status-$n_checked.txt" \
      || rv_fail "gpg exited 0 but emitted no VALIDSIG for $a.asc"
  else
    rv_fail "$a has no detached signature $a.asc"
  fi

  n_checked=$((n_checked + 1))
  rv_log "OK  $a  $actual"
done

[ "$n_checked" -gt 0 ] \
  || rv_fail 'zero artifacts were checked; a verification that checked nothing is not a pass'

printf 'repro-verify: ACCEPTED %d artifact(s), signer %s\n' "$n_checked" "$signer" >&2
exit 0
