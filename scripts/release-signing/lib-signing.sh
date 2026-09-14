# shellcheck shell=sh
# Reprobuild release-signing library — the PRODUCER side of the trust
# relationship the harvesters already implement on the consumer side.
#
# ## Why this is shell and not Nim
#
# The two callers cannot assume a reprobuild binary exists:
#
#   * `.github/workflows/release.yml` signs artifacts BEFORE any
#     reprobuild is published, on a runner whose only reprobuild is the
#     one being released.
#   * the installer verifies BEFORE it installs. A verifier that is
#     itself part of the payload it verifies has verified nothing. So
#     `repro-verify-release.sh` depends on nothing but `gpgv`/`gpg` and
#     `sha256sum` — the same floor `apt-secure` and `dnf` stand on.
#
# ## Why it mirrors apps/repro-harvest-*/src/*/signature.nim
#
# The harvesters verify a FOREIGN repository: they shell out to `gpg` on
# $PATH (or $REPRO_GPG_BIN), import a vendored key bundle into an
# EPHEMERAL keyring, and only then run `gpg --verify`. Every one of
# those choices is reproduced here, for the same reasons:
#
#   * shelling out to gpg, rather than linking a PGP implementation,
#     means reprobuild's producer signs with the same code its consumers
#     verify with, and inherits libgcrypt's algorithm support for free.
#   * $REPRO_GPG_BIN is honoured identically, so a caller that pins gpg
#     for the verifier pins it for the signer.
#   * the EPHEMERAL keyring is not hygiene, it is the test's only
#     guarantee of meaning. gpg is stateful; a verification run against
#     the operator's own ~/.gnupg passes because the operator trusts
#     that key already, and would pass with the artifact's key never
#     imported at all. `rs_ephemeral_gnupghome` makes every verification
#     start from an empty keyring.
#
# ## Where it deliberately DEPARTS from the harvesters
#
# The harvesters fall back to a BLAKE3 fingerprint allowlist when no gpg
# is present. That fallback is right for them — a harvester pinned to a
# frozen snapshot can be pinned by hash instead. It is WRONG here, and
# this library has no equivalent: a producer that cannot sign must fail,
# and a verifier that cannot verify must fail. "gpg missing, so we
# accepted it" is the exact shape of false green the gate forbids.
#
# Sourced by repro-sign-release.sh, repro-sign-apt-repo.sh,
# repro-sign-rpm-repo.sh, repro-sign-pacman-repo.sh and (for the key
# policy only) repro-verify-release.sh.

# ---------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------

# The literal that marks a key as a throwaway. It must appear in a UID
# of every key used for testing. It is spelled in full, in upper case,
# and contains the word UNTRUSTED so that `gpg --list-keys` output read
# by a human says what the key is on the same line as its name.
RS_TEST_KEY_MARKER='REPROBUILD UNTRUSTED TEST KEY'

# Dropped beside SHA256SUMS whenever a `test`-class key signed the
# bundle. `repro-verify-release.sh` refuses a bundle carrying it unless
# the caller passed --allow-test-key, so a test bundle cannot be
# mistaken for a release bundle even if it is copied somewhere else.
RS_TEST_MARKER_FILE='SIGNING-KEY-IS-A-TEST-KEY'

RS_SUMS_FILE='SHA256SUMS'
RS_SUMS_SIG='SHA256SUMS.asc'

# ---------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------

rs_log() { printf 'repro-sign: %s\n' "$*" >&2; }
rs_die() { printf 'repro-sign: FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------
# gpg discovery + invocation
# ---------------------------------------------------------------------

rs_gpg_bin() {
  if [ -n "${REPRO_GPG_BIN:-}" ]; then
    printf '%s\n' "$REPRO_GPG_BIN"
    return 0
  fi
  if command -v gpg >/dev/null 2>&1; then
    command -v gpg
    return 0
  fi
  if command -v gpg2 >/dev/null 2>&1; then
    command -v gpg2
    return 0
  fi
  return 1
}

# Every gpg call in this library goes through rs_gpg. It refuses to run
# unless GNUPGHOME points somewhere this process created, which is what
# stops a signing or verification run from silently using the operator's
# keyring.
rs_gpg() {
  [ -n "${GNUPGHOME:-}" ] || rs_die 'rs_gpg called with no GNUPGHOME'
  [ -n "${RS_GPG:-}" ] || RS_GPG="$(rs_gpg_bin)" || rs_die 'no gpg on PATH and $REPRO_GPG_BIN unset'
  "$RS_GPG" --batch --no-tty --yes \
    --pinentry-mode loopback \
    --keyid-format long "$@"
}

# Create a private GNUPGHOME and arrange for it to be removed. The
# caller gets the path on stdout AND has GNUPGHOME exported.
rs_ephemeral_gnupghome() {
  _rs_home="$(mktemp -d "${TMPDIR:-/tmp}/repro-sign-gnupg-XXXXXX")" \
    || rs_die 'mktemp -d failed'
  chmod 700 "$_rs_home"
  GNUPGHOME="$_rs_home"
  export GNUPGHOME
  RS_EPHEMERAL_HOMES="${RS_EPHEMERAL_HOMES:-} $_rs_home"
  printf '%s\n' "$_rs_home"
}

rs_cleanup_gnupghomes() {
  for _h in ${RS_EPHEMERAL_HOMES:-}; do
    [ -d "$_h" ] || continue
    if [ -n "${RS_GPG:-}" ]; then
      GNUPGHOME="$_h" "$RS_GPG" --batch --quiet \
        --homedir "$_h" --quit-agent >/dev/null 2>&1 || true
    fi
    gpgconf --homedir "$_h" --kill all >/dev/null 2>&1 || true
    rm -rf "$_h"
  done
  RS_EPHEMERAL_HOMES=''
}

# ---------------------------------------------------------------------
# Key classification — release / test / unknown
# ---------------------------------------------------------------------

rs_trusted_keys_file() {
  if [ -n "${REPRO_TRUSTED_RELEASE_KEYS:-}" ]; then
    printf '%s\n' "$REPRO_TRUSTED_RELEASE_KEYS"
  else
    printf '%s\n' "${RS_LIB_DIR}/trusted-release-keys.txt"
  fi
}

# Normalise a fingerprint to bare upper-case hex.
rs_norm_fpr() {
  printf '%s' "$1" | tr -d ' \t:' | tr '[:lower:]' '[:upper:]'
}

# Primary-key fingerprint of $1 (a key spec gpg understands), from the
# CURRENT GNUPGHOME. Empty output + non-zero when the key is absent.
rs_fingerprint_of() {
  _spec="$1"
  rs_gpg --with-colons --fingerprint --list-keys "$_spec" 2>/dev/null \
    | awk -F: '$1=="fpr" {print $10; exit}'
}

# Every UID of $1, one per line, percent-decoded enough for the marker
# test (gpg colon output escapes ':' as '\x3a' and little else that
# matters for an ASCII marker).
rs_uids_of() {
  _spec="$1"
  rs_gpg --with-colons --list-keys "$_spec" 2>/dev/null \
    | awk -F: '$1=="uid" {print $10}'
}

rs_key_is_test() {
  rs_uids_of "$1" | grep -qF "$RS_TEST_KEY_MARKER"
}

rs_key_is_listed_release() {
  _fpr="$(rs_norm_fpr "$1")"
  _file="$(rs_trusted_keys_file)"
  [ -f "$_file" ] || return 1
  # Strip comments, normalise, then require an EXACT line match. A
  # substring match would let a 8-char short id in the file bless a
  # whole key, which is the collision class this list exists to avoid.
  sed 's/#.*//' "$_file" \
    | tr -d ' \t' \
    | tr '[:lower:]' '[:upper:]' \
    | grep -qx "$_fpr"
}

# Prints exactly one of: release | test | unknown
# Exits non-zero (after printing nothing) when the key cannot be found.
rs_key_class() {
  _spec="$1"
  _fpr="$(rs_fingerprint_of "$_spec")"
  [ -n "$_fpr" ] || return 1
  _is_test=no
  _is_rel=no
  rs_key_is_test "$_spec" && _is_test=yes
  rs_key_is_listed_release "$_fpr" && _is_rel=yes
  if [ "$_is_test" = yes ] && [ "$_is_rel" = yes ]; then
    rs_die "key $_fpr is BOTH marked '$RS_TEST_KEY_MARKER' and listed in $(rs_trusted_keys_file); refusing to guess which it is"
  fi
  if [ "$_is_rel" = yes ]; then printf 'release\n'; return 0; fi
  if [ "$_is_test" = yes ]; then printf 'test\n'; return 0; fi
  printf 'unknown\n'
}

# Gate the signing path. Prints the class it admitted.
#
# There is no third outcome and no environment variable that admits an
# `unknown` key: the list is the trust decision, the marker is the
# anti-trust decision, and a key that is neither has had neither
# decision made about it.
rs_require_signing_key() {
  _spec="$1"
  _class="$(rs_key_class "$_spec")" \
    || rs_die "no key matching '$_spec' in GNUPGHOME=$GNUPGHOME"
  _fpr="$(rs_fingerprint_of "$_spec")"
  case "$_class" in
    release)
      rs_log "signing with RELEASE key $_fpr (listed in $(rs_trusted_keys_file))"
      ;;
    test)
      if [ "${REPRO_SIGNING_ALLOW_TEST_KEY:-0}" != 1 ]; then
        rs_die "key $_fpr is a TEST key ('$RS_TEST_KEY_MARKER') and REPRO_SIGNING_ALLOW_TEST_KEY is not 1; refusing to sign"
      fi
      rs_log "signing with TEST key $_fpr — output will carry $RS_TEST_MARKER_FILE"
      ;;
    unknown)
      rs_die "key $_fpr is neither listed in $(rs_trusted_keys_file) nor marked '$RS_TEST_KEY_MARKER'; refusing to sign. Add the fingerprint to the trusted list in a reviewed commit, or mark the key as a test key."
      ;;
    *)
      rs_die "internal: unexpected key class '$_class'"
      ;;
  esac
  printf '%s\n' "$_class"
}

# ---------------------------------------------------------------------
# Artifact signing
# ---------------------------------------------------------------------

# Names that are signing OUTPUT rather than artifacts, and so must never
# appear in SHA256SUMS nor get a detached signature of their own.
rs_is_meta_file() {
  case "$1" in
    "$RS_SUMS_FILE"|"$RS_SUMS_SIG"|"$RS_TEST_MARKER_FILE") return 0 ;;
    *.asc|*.sig|*.sigstore|*.pem|*.sha256) return 0 ;;
    *) return 1 ;;
  esac
}

# List the artifact basenames in $1, sorted, one per line.
rs_artifact_names() {
  _dir="$1"
  for _f in "$_dir"/*; do
    [ -f "$_f" ] || continue
    _b="${_f##*/}"
    rs_is_meta_file "$_b" && continue
    printf '%s\n' "$_b"
  done | LC_ALL=C sort
}

# SHA256SUMS over every artifact in $1. Sorted by name (stable, diffable,
# and reproducible across runners) and written with the two-space
# `sha256sum` separator so `sha256sum -c` reads it back.
rs_write_sha256sums() {
  _dir="$1"
  command -v sha256sum >/dev/null 2>&1 \
    || rs_die 'sha256sum not found; refusing to emit an unverifiable manifest'
  # The scratch manifest is built OUTSIDE the artifact directory. Built
  # inside it, it is itself picked up as an artifact on the very next
  # `rs_artifact_names` call -- the first run of this library emitted a
  # three-line manifest for two artifacts because of exactly that, and
  # it was the count assertion in repro-sign-release.sh, not the
  # manifest, that said so.
  _tmp="$(mktemp "${TMPDIR:-/tmp}/repro-sums-XXXXXX")" || rs_die 'mktemp failed'
  _n=0
  rs_artifact_names "$_dir" | while IFS= read -r _b; do
    ( cd "$_dir" && sha256sum "$_b" ) >> "$_tmp"
  done
  _n="$(wc -l < "$_tmp" | tr -d ' ')"
  if [ "$_n" -lt 1 ]; then
    rm -f "$_tmp"
    rs_die "no artifacts found in $_dir; refusing to sign an empty manifest"
  fi
  mv "$_tmp" "$_dir/$RS_SUMS_FILE"
  chmod 644 "$_dir/$RS_SUMS_FILE"
  rs_log "wrote $RS_SUMS_FILE covering $_n artifact(s)"
  printf '%s\n' "$_n"
}

# Detached, armoured signature of $2 at $2.asc, by key $1.
rs_detach_sign() {
  _key="$1"; _path="$2"
  rm -f "$_path.asc"
  rs_gpg --local-user "$_key" --armor --detach-sign \
    --output "$_path.asc" "$_path" \
    || rs_die "gpg --detach-sign failed for $_path"
  [ -s "$_path.asc" ] || rs_die "gpg produced an empty signature for $_path"
}

# Clearsigned copy of $2 at $3, by key $1.
rs_clearsign() {
  _key="$1"; _in="$2"; _out="$3"
  rm -f "$_out"
  rs_gpg --local-user "$_key" --clearsign --output "$_out" "$_in" \
    || rs_die "gpg --clearsign failed for $_in"
  [ -s "$_out" ] || rs_die "gpg produced an empty clearsigned file for $_in"
}

# ---------------------------------------------------------------------
# cosign keyless — the code path, and the honest refusal
# ---------------------------------------------------------------------
#
# Keyless signing derives the signing identity from an ambient OIDC
# token. There are exactly two places one can come from:
#
#   * a CI workload identity — on GitHub Actions, the runner exposes
#     $ACTIONS_ID_TOKEN_REQUEST_URL + $ACTIONS_ID_TOKEN_REQUEST_TOKEN to
#     a job that declared `permissions: id-token: write`; cosign
#     exchanges them for a Fulcio certificate itself.
#   * an operator's interactive browser flow, which is not available in
#     a non-interactive signer and is not a release mechanism.
#
# Neither can be conjured locally. This function therefore REFUSES with
# a specific diagnosis rather than substituting anything, and callers
# treat exit 2 as "keyless unavailable here", never as "keyless done".

rs_cosign_available() {
  command -v cosign >/dev/null 2>&1
}

rs_cosign_oidc_available() {
  # GitHub Actions workload identity.
  if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] \
     && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    return 0
  fi
  # An explicitly supplied token (other CI systems, or a federated
  # identity minted by the governance pipeline).
  if [ -n "${SIGSTORE_ID_TOKEN:-}" ]; then
    return 0
  fi
  return 1
}

# Sign $1 keylessly. Exit 0 = signed; exit 2 = not attempted, with the
# reason on stderr; exit 1 = attempted and failed.
rs_cosign_sign_blob() {
  _path="$1"
  if ! rs_cosign_available; then
    rs_log "cosign keyless SKIPPED for $_path: no 'cosign' on PATH"
    return 2
  fi
  if ! rs_cosign_oidc_available; then
    rs_log "cosign keyless SKIPPED for $_path: no ambient OIDC identity (need ACTIONS_ID_TOKEN_REQUEST_URL + ACTIONS_ID_TOKEN_REQUEST_TOKEN from a job with 'permissions: id-token: write', or SIGSTORE_ID_TOKEN). Refusing to fabricate one."
    return 2
  fi
  cosign sign-blob --yes \
    --bundle "$_path.sigstore" \
    "$_path" >/dev/null \
    || { rs_log "cosign sign-blob FAILED for $_path"; return 1; }
  [ -s "$_path.sigstore" ] \
    || { rs_log "cosign produced an empty bundle for $_path"; return 1; }
  rs_log "cosign keyless bundle written: $_path.sigstore"
  return 0
}
