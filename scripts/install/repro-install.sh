#!/bin/sh
# Reprobuild installer — the POSIX half of M3.
#
#   curl -fsSL https://get.reprobuild.com/sh | sh
#   curl -fsSL https://get.reprobuild.com/sh | sh -s -- --method tarball
#   curl -fsSL https://get.reprobuild.com/sh | sh -s -- --uninstall
#
# detect -> verify -> register the native repo -> let the PACKAGE MANAGER
# install. After that, `apt upgrade` / `dnf upgrade` / `pacman -Syu` move
# the user to newer releases with no further involvement from this script.
# That is the whole point of registering a repository instead of dropping
# a tarball in /usr/local: updates stop being our problem.
#
# ## What this script does NOT do
#
# It does not verify the repository metadata itself. apt, dnf and pacman
# do that natively, from the trust anchor registered in step 3, on every
# transaction — including ones that happen months from now with this
# script long gone. A script that re-implemented those checks would be
# both redundant and weaker. What this script is responsible for is
# getting the RIGHT trust anchor onto the box, and refusing to proceed
# when it cannot.
#
# ## The trust anchor, and why it is pinned by digest
#
# Registering a repository means installing a public key that will be
# trusted for every future upgrade. That key cannot be verified by a
# signature made with itself, so something has to root the trust:
#
#   * HTTPS to the keyring host (authenticates the host, not the bytes);
#   * PLUS a SHA-256 digest of the expected keyring, baked into THIS
#     script (`REPRO_KEYRING_SHA256`).
#
# The digest is what makes a compromised or substituted keyring host
# insufficient. It works because the user obtained this script over the
# same HTTPS they are about to distrust — the pin does not create trust
# out of nothing, it forces an attacker to compromise the install host
# and the keyring host consistently, and makes the substitution visible
# in a diff of this file.
#
# The keyring is NOT fetched from the release page. Verifying a release
# against a key published beside it is circular; see
# docs/release-signing.md, "Where the external boundary falls".
#
# ## Where the tarball fallback verification comes from
#
# The repo-less path (--method tarball) downloads artifacts and MUST NOT
# unpack them unverified. It calls M2's `repro-verify-release.sh`, which
# treats a missing gpg, a missing signature and a missing manifest line
# as rejections. This script never re-implements that check and never
# proceeds past a non-zero exit from it.
#
# ## One repository for every Metacraft product
#
# The apt and RPM repositories are the ORGANISATION's, not reprobuild's:
# deb.metacraft-labs.com and rpm.metacraft-labs.com carry every Metacraft
# product, signed with one organisation key (metacraft-specs
# infrastructure/package-distribution.md §3, §13). So the source entry and
# the key this script writes are SHARED: every product's installer writes
# the same files, and installing a second product reuses them. Each
# product records itself under $REPO_USERS_DIR, and --uninstall removes
# the shared entry only when no other product remains.
#
# ## Idempotence
#
# Every write is to a FIXED path and is a replacement, never an append:
# one keyring file, one sources file. The single append-structured
# format (pacman.conf) is guarded by a marker block that is rewritten in
# place. Running this script twice registers one repository, installs one
# package, and leaves one keyring.

set -eu

PRODUCT='Reprobuild'
PKG_NAME="${REPRO_PKG_NAME:-reprobuild}"

# ---------------------------------------------------------------------
# THE configurable base URL.
#
# REPRO_BASE_URL is the single knob. Unset (the default) the installer
# talks to the production per-ecosystem subdomains under $REPRO_DOMAIN.
# Set, EVERY fetch becomes a path under that one base:
#
#   $REPRO_BASE_URL/deb        apt repository root
#   $REPRO_BASE_URL/rpm        dnf/yum repository root
#   $REPRO_BASE_URL/arch       pacman repository root
#   $REPRO_BASE_URL/downloads  release tarballs + SHA256SUMS{,.asc}
#   $REPRO_BASE_URL/keys/<keyring-file>
#
# so the whole installer can be pointed at a local HTTP server with one
# variable and no edits. The gate does exactly that. Nothing below
# hardcodes a production hostname in a way that only resolves against
# the real zone — which is deliberate: reprobuild.com's delegation was
# still in flight when this was written, and an installer that can only
# be tested against DNS that does not exist yet cannot be tested at all.
#
# Individual URLs can still be overridden one at a time, which is what a
# mirror or an air-gapped site needs.
# ---------------------------------------------------------------------
REPRO_REPO_DOMAIN="${REPRO_REPO_DOMAIN:-metacraft-labs.com}"

if [ -n "${REPRO_BASE_URL:-}" ]; then
  _b="${REPRO_BASE_URL%/}"
  REPRO_DEB_URL="${REPRO_DEB_URL:-$_b/deb}"
  REPRO_RPM_URL="${REPRO_RPM_URL:-$_b/rpm}"
  REPRO_ARCH_URL="${REPRO_ARCH_URL:-$_b/arch}"
  REPRO_DOWNLOADS_URL="${REPRO_DOWNLOADS_URL:-$_b/downloads}"
  REPRO_KEYS_URL="${REPRO_KEYS_URL:-$_b/keys}"
else
  REPRO_DEB_URL="${REPRO_DEB_URL:-https://deb.$REPRO_REPO_DOMAIN}"
  REPRO_RPM_URL="${REPRO_RPM_URL:-https://rpm.$REPRO_REPO_DOMAIN}"
  # EMPTY: the organisation has no pacman repository yet, so Arch installs
  # from the signed tarball. Setting this is how a mirror, or the gate,
  # offers one.
  REPRO_ARCH_URL="${REPRO_ARCH_URL:-}"
  # Release assets are served from the GitHub Release, at the
  # <base>/v<version>/<asset> shape this script fetches.
  REPRO_DOWNLOADS_URL="${REPRO_DOWNLOADS_URL:-https://github.com/metacraft-labs/reprobuild/releases/download}"
  REPRO_KEYS_URL="${REPRO_KEYS_URL:-https://deb.$REPRO_REPO_DOMAIN/keys}"
fi

# The organisation's key, ASCII-armoured. Armoured because every consumer
# takes it that way with no conversion: apt reads an armoured Signed-By
# keyring when its name ends in .asc, rpm --import requires armour, and
# pacman-key --add accepts it. So no gpg is needed on the client to use it.
KEYRING_FILE="${REPRO_KEYRING_FILE:-metacraft-labs-archive-keyring.asc}"
KEYRING_DEST="${REPRO_KEYRING_DEST:-/usr/share/keyrings/$KEYRING_FILE}"

# The expected SHA-256 of the keyring at $REPRO_KEYS_URL/$KEYRING_FILE:
# the organisation key 3CA0 3287 4B65 1B0C F01D  FB67 7EAF 585F B9B5 9164,
# as committed in metacraft-labs/metacraft-desktop-packages keys/ and
# uploaded from there verbatim, so its bytes do not change. Changing this
# line is a key rotation. An empty value (a mirror that sets it so) makes
# the installer FAIL CLOSED; REPRO_ALLOW_UNPINNED_KEYRING=1 is the only way
# past that, it is never set by default, and it warns what it costs.
REPRO_KEYRING_SHA256="${REPRO_KEYRING_SHA256-27d3273b8e90f966d9557420aaa13446ee8b1b2c6da027137a094f5322da68fc}"

# Suite/component/repo-id the release pipeline publishes under. These
# must agree with scripts/release/repro-publish-repos.sh; they are
# variables here so a staging channel is a flag, not a fork.
APT_SUITE="${REPRO_APT_SUITE:-stable}"
APT_COMPONENT="${REPRO_APT_COMPONENT:-main}"
RPM_REPO_ID="${REPRO_RPM_REPO_ID:-metacraft-labs}"
ARCH_REPO_NAME="${REPRO_ARCH_REPO_NAME:-metacraft}"

APT_SOURCES_DEST="${REPRO_APT_SOURCES_DEST:-/etc/apt/sources.list.d/metacraft-labs.sources}"
RPM_REPO_DEST="${REPRO_RPM_REPO_DEST:-/etc/yum.repos.d/metacraft-labs.repo}"
# The ASCII-armoured copy of the trust anchor that rpm/dnf consume. A
# FIXED path, so a second run replaces it instead of adding another.
# The organisation's anchor is already armoured, so it is used as is.
case "$KEYRING_DEST" in
  *.asc) _rpm_key_default="$KEYRING_DEST" ;;
  *)     _rpm_key_default="${KEYRING_DEST}.asc" ;;
esac
RPM_KEY_ARMOURED="${REPRO_RPM_KEY_ARMOURED:-$_rpm_key_default}"
PACMAN_CONF="${REPRO_PACMAN_CONF:-/etc/pacman.conf}"
PACMAN_BEGIN='# >>> metacraft-labs repository >>>'
PACMAN_END='# <<< metacraft-labs repository <<<'
# One file per Metacraft product that relies on the shared entry above.
REPO_USERS_DIR="${REPRO_REPO_USERS_DIR:-/var/lib/metacraft-labs/repository-users}"

TARBALL_PREFIX="${REPRO_INSTALL_PREFIX:-/usr/local}"
# Where a tarball install records what it put down, so --uninstall can
# remove exactly that and nothing else. A tarball uninstall that globs
# $prefix/bin would delete files it never installed.
TARBALL_MANIFEST="${REPRO_TARBALL_MANIFEST:-/var/lib/reprobuild/installed-files.txt}"

method='auto'
do_uninstall=0
dry_run=0
want_version=''
verify_script="${REPRO_VERIFY_SCRIPT:-}"

log()  { printf '[%s installer] %s\n' "$PRODUCT" "$*" >&2; }
warn() { printf '[%s installer] WARNING: %s\n' "$PRODUCT" "$*" >&2; }
die()  { printf '[%s installer] ERROR: %s\n' "$PRODUCT" "$*" >&2; exit 1; }
run()  {
  if [ "$dry_run" -eq 1 ]; then
    printf '[%s installer] DRY-RUN would run: %s\n' "$PRODUCT" "$*" >&2
    return 0
  fi
  "$@"
}

usage() {
  cat <<'USAGE'
Usage: repro-install.sh [OPTIONS]

  --method auto|apt|dnf|pacman|tarball|scoop
                        Install method. "auto" detects the native package
                        manager and falls back to "tarball" when there is
                        no repository for this platform.
  --version VERSION     Install this exact version instead of the newest.
  --uninstall           Remove the package, the repository registration
                        and the trust anchor, then assert they are gone.
  --prefix PATH         Tarball-install prefix (default /usr/local).
  --dry-run             Print the commands that would run; change nothing.
  --yes                 Do not prompt.
  -h, --help            This text.

Environment (see the comment block at the top of this file):
  REPRO_BASE_URL        Point every fetch at one base URL. This is the
                        single knob that retargets the installer at a
                        local or mirrored host.
  REPRO_REPO_DOMAIN     Repository domain (default metacraft-labs.com),
                        used only when REPRO_BASE_URL is unset.
  REPRO_DEB_URL REPRO_RPM_URL REPRO_ARCH_URL REPRO_DOWNLOADS_URL
  REPRO_KEYS_URL        Per-ecosystem overrides.
  REPRO_KEYRING_SHA256  Expected SHA-256 of the trust anchor (pinned to
                        the organisation key; empty fails closed).
  REPRO_ALLOW_UNPINNED_KEYRING=1
                        Proceed with an unpinned keyring. For tests only.
  REPRO_VERIFY_SCRIPT   Path to repro-verify-release.sh (tarball method).
  REPRO_ALLOW_TEST_KEY=1
                        Pass --allow-test-key to the verifier.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --method) [ $# -ge 2 ] || die '--method requires an argument'; method="$2"; shift 2 ;;
    --version) [ $# -ge 2 ] || die '--version requires an argument'; want_version="$2"; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die '--prefix requires an argument'; TARBALL_PREFIX="$2"; shift 2 ;;
    --uninstall|--remove) do_uninstall=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    # Accepted and ignored, deliberately. This installer NEVER prompts —
    # a prompt in a `curl | sh` pipeline has no tty and hangs — so there
    # is nothing for --yes to confirm. It is accepted because people type
    # it out of habit and failing on it would be gratuitous.
    --yes|-y) shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------
# 1. detect
# ---------------------------------------------------------------------

DISTRO_ID=''
DISTRO_LIKE=''
DISTRO_CODENAME=''
detect_distro() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-}"
    DISTRO_LIKE="${ID_LIKE:-}"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"
  fi
  [ -n "$DISTRO_ID" ] || DISTRO_ID="$(uname -s | tr '[:upper:]' '[:lower:]')"
}

# Map uname -m onto the arch token reprobuild's release assets use. An
# unrecognised machine is an error, not a guess: silently installing an
# x86_64 build on a machine that is not x86_64 fails later, further from
# the cause.
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo 'x86_64' ;;
    aarch64|arm64) echo 'aarch64' ;;
    *) die "unsupported machine $(uname -m); see .github/release-platforms.json for the platforms reprobuild publishes" ;;
  esac
}

detect_platform() {
  case "$(uname -s)" in
    Linux)  echo 'linux' ;;
    Darwin) echo 'darwin' ;;
    *) die "unsupported kernel $(uname -s); on Windows use the PowerShell installer (scripts/install/repro-install.ps1)" ;;
  esac
}

# Which native repository, if any, serves this box. Falls through to
# tarball rather than failing: a distro we do not publish a repo for is
# still a distro reprobuild runs on.
detect_method() {
  _f=''
  case " $DISTRO_ID $DISTRO_LIKE " in
    *' debian '*|*' ubuntu '*) _f='apt' ;;
    *' rhel '*|*' fedora '*|*' centos '*) _f='dnf' ;;
    *' arch '*|*' archlinux '*)
      if [ -n "$REPRO_ARCH_URL" ]; then _f='pacman'
      else log 'there is no Metacraft pacman repository yet; using the signed tarball fallback'; _f='tarball'
      fi ;;
  esac
  if [ -z "$_f" ]; then
    if command -v apt-get >/dev/null 2>&1; then _f='apt'
    elif command -v dnf >/dev/null 2>&1 || command -v dnf5 >/dev/null 2>&1; then _f='dnf'
    elif command -v pacman >/dev/null 2>&1 && [ -n "$REPRO_ARCH_URL" ]; then _f='pacman'
    fi
  fi
  if [ -z "$_f" ]; then
    log "no supported native package manager detected (ID=$DISTRO_ID ID_LIKE=$DISTRO_LIKE); using the signed tarball fallback"
    _f='tarball'
  fi
  echo "$_f"
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "this step needs root; re-run under sudo (installing a system repository writes to $KEYRING_DEST)"
}

# ---------------------------------------------------------------------
# download helpers
# ---------------------------------------------------------------------

DL=''
pick_downloader() {
  if command -v curl >/dev/null 2>&1; then DL='curl'
  elif command -v wget >/dev/null 2>&1; then DL='wget'
  else
    die 'neither curl nor wget is available; cannot fetch anything. (If you reached this script with curl, curl is installed but not on this PATH.)'
  fi
}

# fetch <url> <dest>. Fails on HTTP errors — curl without -f exits 0
# having written an error page, which would then be "verified" as a
# corrupt keyring instead of reported as a 404.
fetch() {
  _url="$1"; _dest="$2"
  [ -n "$DL" ] || pick_downloader
  log "fetch $_url"
  case "$DL" in
    curl) curl -fsSL --proto '=https,http' --retry 3 -o "$_dest" "$_url" \
            || die "download failed: $_url" ;;
    wget) wget -q -O "$_dest" "$_url" || die "download failed: $_url" ;;
  esac
  [ -s "$_dest" ] || die "downloaded an empty file from $_url"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die 'no sha256sum/shasum available; cannot check the trust anchor digest'
  fi
}

# ---------------------------------------------------------------------
# 2. verify — the trust anchor
# ---------------------------------------------------------------------

# Fetch the keyring and check it against the pinned digest. The ONLY
# ways past a mismatch are a correct digest or an explicit opt-out; the
# opt-out is never the default and says what it costs.
install_trust_anchor() {
  _tmp="$1"
  _kr="$_tmp/$KEYRING_FILE"

  if [ -n "${REPRO_KEYRING_LOCAL:-}" ]; then
    # A locally supplied anchor (the gate, an air-gapped mirror). Still
    # digest-checked when a digest is pinned — "it came from a file"
    # is not a reason to skip the check.
    [ -f "$REPRO_KEYRING_LOCAL" ] || die "REPRO_KEYRING_LOCAL=$REPRO_KEYRING_LOCAL does not exist"
    cp "$REPRO_KEYRING_LOCAL" "$_kr"
    log "trust anchor taken from REPRO_KEYRING_LOCAL=$REPRO_KEYRING_LOCAL"
  else
    fetch "$REPRO_KEYS_URL/$KEYRING_FILE" "$_kr"
  fi

  _got="$(sha256_of "$_kr")"
  if [ -n "$REPRO_KEYRING_SHA256" ]; then
    if [ "$_got" = "$REPRO_KEYRING_SHA256" ]; then
      log "trust anchor digest OK ($_got)"
    else
      die "trust anchor digest MISMATCH
  expected $REPRO_KEYRING_SHA256
  got      $_got
Refusing to install a repository key that is not the one this installer pins.
This is what a substituted keyring host looks like. Do not override it."
    fi
  elif [ "${REPRO_ALLOW_UNPINNED_KEYRING:-0}" = '1' ]; then
    warn "installing an UNPINNED trust anchor (sha256=$_got) because REPRO_ALLOW_UNPINNED_KEYRING=1."
    warn "Every future upgrade on this machine will trust whatever key that was. Not for production."
  else
    die "no trust anchor digest is pinned (REPRO_KEYRING_SHA256 is empty).
This installer fails closed rather than trusting the keyring host blindly.
To install anyway, in a test, set REPRO_ALLOW_UNPINNED_KEYRING=1 and
understand that you are opting out of the only thing that roots
repository trust."
  fi

  # Replacement, not accumulation: one file, fixed path. This is half of
  # why a second run changes nothing.
  run mkdir -p "$(dirname "$KEYRING_DEST")"
  run cp "$_kr" "$KEYRING_DEST"
  run chmod 0644 "$KEYRING_DEST"
  log "trust anchor installed at $KEYRING_DEST"
}

# ---------------------------------------------------------------------
# the shared entry's users
# ---------------------------------------------------------------------

# The source entry and the key are shared by every Metacraft product
# (see the header). A product that uses them says so here, and only the
# LAST one to leave removes them: uninstalling reprobuild must not cut
# CodeTracer off from its updates.
claim_shared_entry()   { run mkdir -p "$REPO_USERS_DIR"; run touch "$REPO_USERS_DIR/$PKG_NAME"; }
release_shared_entry() { run rm -f "$REPO_USERS_DIR/$PKG_NAME"; }
other_shared_users() {
  [ -d "$REPO_USERS_DIR" ] || return 0
  for _u in "$REPO_USERS_DIR"/*; do
    [ -e "$_u" ] || continue
    [ "$(basename "$_u")" = "$PKG_NAME" ] || basename "$_u"
  done
}

# ---------------------------------------------------------------------
# 3. register the native repo + 4. let the package manager install
# ---------------------------------------------------------------------

apt_arch() {
  if command -v dpkg >/dev/null 2>&1; then dpkg --print-architecture; else echo amd64; fi
}

register_apt() {
  _a="$(apt_arch)"
  log "registering apt repository $REPRO_DEB_URL ($APT_SUITE/$APT_COMPONENT/$_a)"
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN would write $APT_SOURCES_DEST"
    return 0
  fi
  mkdir -p "$(dirname "$APT_SOURCES_DEST")"
  # deb822, written whole. `>` not `>>`: a second run replaces this file
  # rather than adding a second stanza, so apt never sees the repository
  # twice. Signed-By pins the trust anchor to THIS repository instead of
  # adding it to apt's global trust (which is what the deprecated
  # apt-key add did, and why it is deprecated).
  cat > "$APT_SOURCES_DEST" <<SOURCES
Types: deb
URIs: $REPRO_DEB_URL
Suites: $APT_SUITE
Components: $APT_COMPONENT
Architectures: $_a
Signed-By: $KEYRING_DEST
SOURCES
  chmod 0644 "$APT_SOURCES_DEST"
}

install_apt() {
  export DEBIAN_FRONTEND=noninteractive
  # `apt-get update` here is apt verifying our InRelease against the
  # anchor we just installed. If the repository is unsigned, signed by
  # the wrong key, or tampered with, THIS is where it fails, with apt's
  # message and apt's exit code. We do not parse it and we do not
  # continue past it.
  run apt-get update || die 'apt-get update failed; the repository was not accepted (see apt output above)'
  _target="$PKG_NAME"
  [ -z "$want_version" ] || _target="$PKG_NAME=$want_version"
  run apt-get install -y "$_target" \
    || die "apt-get install $_target failed (see apt output above)"
}

remove_apt() {
  export DEBIAN_FRONTEND=noninteractive
  if dpkg-query -W -f='${Status}' "$PKG_NAME" 2>/dev/null | grep -q 'install ok installed'; then
    run apt-get remove -y --purge "$PKG_NAME" || die "apt-get remove $PKG_NAME failed"
  else
    log "$PKG_NAME is not installed; nothing for apt to remove"
  fi
  [ -n "$(other_shared_users)" ] || run rm -f "$APT_SOURCES_DEST"
}

register_dnf() {
  log "registering dnf repository $REPRO_RPM_URL"
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN would write $RPM_REPO_DEST"
    return 0
  fi
  mkdir -p "$(dirname "$RPM_REPO_DEST")"
  # gpgkey= is consumed by dnf for repo_gpgcheck and by rpm for gpgcheck;
  # both are happiest with ASCII armour, and rpm --import REQUIRES it. One
  # normalised copy at a fixed path serves both, and being a fixed path it
  # is replaced rather than accumulated on a second run.
  armour_keyring_to "$KEYRING_DEST" "$RPM_KEY_ARMOURED"
  # gpgcheck AND repo_gpgcheck. Neither implies the other: gpgcheck
  # covers package headers, repo_gpgcheck covers repomd.xml. A repo with
  # signed metadata consumed with repo_gpgcheck=0 is an unsigned repo.
  # See docs/release-signing.md.
  cat > "$RPM_REPO_DEST" <<REPO
[$RPM_REPO_ID]
name=Metacraft Labs
baseurl=$REPRO_RPM_URL
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$RPM_KEY_ARMOURED
REPO
  chmod 0644 "$RPM_REPO_DEST"
}

dnf_bin() {
  if command -v dnf5 >/dev/null 2>&1; then echo dnf5
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  else die 'no dnf/dnf5/yum found'
  fi
}

# `rpm --import` accepts ONLY an ASCII-armoured public key: handed a
# binary keyring it fails with "key 1 not an armored public key". apt, by
# contrast, is conventionally given a binary keyring. The trust anchor
# therefore has to be normalised rather than assumed, because the two
# ecosystems' publishers legitimately emit different encodings of the
# same key (M2's apt signer exports binary, its rpm signer armoured) and
# an installer that only handled one would fail on whichever repository
# it was not written against.
#
# This was found by a gate step that "rejected" an adversary key and was
# in fact only failing to import a binary file — a rejection that proved
# nothing about trust. Normalising here is what lets that step test trust.
armour_keyring_to() {
  _src="$1"; _dst="$2"
  if head -c 64 "$_src" 2>/dev/null | grep -q 'BEGIN PGP PUBLIC KEY BLOCK'; then
    [ "$_src" = "$_dst" ] || cp "$_src" "$_dst"
    return 0
  fi
  command -v gpg >/dev/null 2>&1 \
    || die "the trust anchor $_src is a binary keyring and rpm --import needs ASCII armour, but gpg is not available to convert it.
Refusing to continue: this is a missing tool, not a reason to skip verification."
  _h="$(mktemp -d)"
  chmod 700 "$_h"
  # Ephemeral GNUPGHOME, never ~/.gnupg. gpg is stateful, and converting
  # through the operator's keyring could export a DIFFERENT key that
  # happened to be there.
  if ! GNUPGHOME="$_h" gpg --batch --quiet --import "$_src" >/dev/null 2>&1; then
    rm -rf "$_h"
    die "could not import the trust anchor $_src to re-encode it"
  fi
  if ! GNUPGHOME="$_h" gpg --batch --armor --export > "$_dst" 2>/dev/null; then
    rm -rf "$_h"
    die "could not ASCII-armour the trust anchor $_src"
  fi
  rm -rf "$_h"
  [ -s "$_dst" ] || die "re-encoding the trust anchor $_src produced an empty file"
  log 'trust anchor re-encoded as ASCII armour for rpm --import'
}

install_dnf() {
  _d="$(dnf_bin)"
  # rpm must be told to trust the key before a gpgcheck'd install; dnf
  # would otherwise prompt, and a prompt in a curl|sh pipeline is a hang.
  # This is a scoped import of the SAME digest-pinned anchor.
  # register_dnf already produced the armoured copy at a fixed path.
  run rpm --import "$RPM_KEY_ARMOURED" || die "rpm --import $RPM_KEY_ARMOURED failed"
  _target="$PKG_NAME"
  [ -z "$want_version" ] || _target="$PKG_NAME-$want_version"
  run "$_d" -y makecache || die "$_d makecache failed; the repository was not accepted"
  run "$_d" -y install "$_target" || die "$_d install $_target failed (see output above)"
}

remove_dnf() {
  _d="$(dnf_bin)"
  if rpm -q "$PKG_NAME" >/dev/null 2>&1; then
    run "$_d" -y remove "$PKG_NAME" || die "$_d remove $PKG_NAME failed"
  else
    log "$PKG_NAME is not installed; nothing for dnf to remove"
  fi
  [ -z "$(other_shared_users)" ] || return 0
  run rm -f "$RPM_REPO_DEST" "$RPM_KEY_ARMOURED"
  # rpm keeps imported keys as pseudo-packages. Leaving ours behind
  # would mean "uninstalled" still trusts us for future signatures.
  for _k in $(rpm -qa 'gpg-pubkey*' 2>/dev/null || true); do
    if rpm -qi "$_k" 2>/dev/null | grep -qiE 'reprobuild|metacraft labs'; then
      log "removing imported rpm key $_k"
      run rpm -e --allmatches "$_k" || warn "could not remove rpm key $_k"
    fi
  done
}

register_pacman() {
  log "registering pacman repository $REPRO_ARCH_URL"
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN would add a [$ARCH_REPO_NAME] block to $PACMAN_CONF"
    return 0
  fi
  [ -f "$PACMAN_CONF" ] || die "$PACMAN_CONF not found"

  # pacman.conf is the one append-structured config here, so idempotence
  # cannot come from "write the whole file". Instead the block is fenced
  # by markers and REPLACED: strip any previous block, then append one.
  # Appending without the strip is how a third run produces a
  # "duplicated database" error from pacman.
  _tmpconf="$PACMAN_CONF.reprobuild.$$"
  awk -v b="$PACMAN_BEGIN" -v e="$PACMAN_END" '
    $0 == b { skip = 1 }
    skip != 1 { print }
    $0 == e { skip = 0 }
  ' "$PACMAN_CONF" > "$_tmpconf"

  # SigLevel Required DatabaseRequired: sign the packages AND the sync
  # database. Arch's default DatabaseOptional leaves the database
  # unverified, which is one MITM away from a silent downgrade.
  {
    printf '%s\n' "$PACMAN_BEGIN"
    printf '[%s]\n' "$ARCH_REPO_NAME"
    printf 'SigLevel = Required DatabaseRequired\n'
    printf 'Server = %s\n' "$REPRO_ARCH_URL"
    printf '%s\n' "$PACMAN_END"
  } >> "$_tmpconf"

  mv "$_tmpconf" "$PACMAN_CONF"

  run pacman-key --init || die 'pacman-key --init failed'
  run pacman-key --add "$KEYRING_DEST" || die "pacman-key --add $KEYRING_DEST failed"
  # A key pacman has not locally signed is not trusted for package
  # verification, however present it is in the keyring.
  _fprs="$(gpg --show-keys --with-colons "$KEYRING_DEST" 2>/dev/null | awk -F: '$1=="fpr"{print $10}')"
  [ -n "$_fprs" ] || die "no OpenPGP key found in $KEYRING_DEST"
  for _f in $_fprs; do
    run pacman-key --lsign-key "$_f" || die "pacman-key --lsign-key $_f failed"
  done
}

install_pacman() {
  run pacman -Sy --noconfirm || die 'pacman -Sy failed; the repository was not accepted'
  _target="$ARCH_REPO_NAME/$PKG_NAME"
  run pacman -S --noconfirm "$_target" || die "pacman -S $_target failed (see output above)"
}

remove_pacman() {
  if pacman -Q "$PKG_NAME" >/dev/null 2>&1; then
    run pacman -Rns --noconfirm "$PKG_NAME" || die "pacman -Rns $PKG_NAME failed"
  else
    log "$PKG_NAME is not installed; nothing for pacman to remove"
  fi
  [ -z "$(other_shared_users)" ] || return 0
  if [ "$dry_run" -eq 0 ] && [ -f "$PACMAN_CONF" ]; then
    _tmpconf="$PACMAN_CONF.reprobuild.$$"
    awk -v b="$PACMAN_BEGIN" -v e="$PACMAN_END" '
      $0 == b { skip = 1 }
      skip != 1 { print }
      $0 == e { skip = 0 }
    ' "$PACMAN_CONF" > "$_tmpconf"
    mv "$_tmpconf" "$PACMAN_CONF"
  fi
  _fprs="$(gpg --show-keys --with-colons "$KEYRING_DEST" 2>/dev/null | awk -F: '$1=="fpr"{print $10}' || true)"
  for _f in $_fprs; do
    run pacman-key --delete "$_f" >/dev/null 2>&1 || true
  done
}

# ---------------------------------------------------------------------
# the repo-less fallback: signed tarball
# ---------------------------------------------------------------------

# Locate M2's verifier. The tarball path MUST NOT run without it: an
# installer that cannot find its verifier and unpacks anyway has no
# security property at all, so a missing verifier is a hard failure,
# never a warning.
locate_verifier() {
  if [ -n "$verify_script" ]; then
    [ -f "$verify_script" ] || die "REPRO_VERIFY_SCRIPT=$verify_script does not exist"
    echo "$verify_script"; return 0
  fi
  _self_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)" || _self_dir=''
  # `[ -f x ] && { ...; }` as a loop body would make `set -e` exit the
  # script on the FIRST candidate that does not exist. Use `if`.
  for _c in \
    "$_self_dir/../release-signing/repro-verify-release.sh" \
    "$_self_dir/repro-verify-release.sh" ; do
    if [ -f "$_c" ]; then
      echo "$_c"; return 0
    fi
  done
  die 'cannot locate repro-verify-release.sh.
The tarball fallback verifies signatures BEFORE unpacking and will not
run without the verifier. Set REPRO_VERIFY_SCRIPT, or fetch the verifier
alongside this installer. It will not proceed unverified.'
}

install_tarball() {
  _plat="$(detect_platform)"
  _arch="$(detect_arch)"
  _ver="$want_version"
  if [ -z "$_ver" ]; then
    # An explicit version is required rather than guessed: "latest"
    # resolution belongs to the release index, and silently installing
    # whatever a directory listing happened to sort last is not a
    # release policy. The gate always passes --version.
    if [ -n "${REPRO_VERSION:-}" ]; then
      _ver="$REPRO_VERSION"
    else
      die 'the tarball fallback needs --version (or REPRO_VERSION).
There is no "latest" symlink to follow: resolving "latest" from a
directory listing is not a release policy, and guessing is worse.'
    fi
  fi

  _asset="reprobuild-$_ver-$_plat-$_arch.tar.gz"
  _vs="$(locate_verifier)"
  _tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$_tmp'" EXIT INT TERM

  fetch "$REPRO_DOWNLOADS_URL/v$_ver/$_asset"       "$_tmp/$_asset"
  fetch "$REPRO_DOWNLOADS_URL/v$_ver/SHA256SUMS"     "$_tmp/SHA256SUMS"
  fetch "$REPRO_DOWNLOADS_URL/v$_ver/SHA256SUMS.asc" "$_tmp/SHA256SUMS.asc"
  # The per-artifact detached signature. Not redundant with the manifest:
  # it is what lets a consumer that fetched ONE asset verify it, while
  # the manifest signature is what binds the set (so a REMOVED artifact
  # is also detectable).
  fetch "$REPRO_DOWNLOADS_URL/v$_ver/$_asset.asc"   "$_tmp/$_asset.asc"

  # The trust anchor for the tarball path, same pin as the repo path.
  install_trust_anchor "$_tmp"

  _vargs=''
  [ "${REPRO_ALLOW_TEST_KEY:-0}" = '1' ] && _vargs='--allow-test-key'

  log "verifying $_asset with $_vs BEFORE unpacking"
  # No `|| true`, no rescue branch. M2's verifier exits non-zero for a
  # bad signature, a missing signature, a missing manifest line and a
  # missing gpg alike, and each of those must stop the install.
  # shellcheck disable=SC2086
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN would verify and unpack $_asset"
    return 0
  fi
  sh "$_vs" --keyring "$KEYRING_DEST" --dir "$_tmp" --artifact "$_asset" $_vargs \
    || die 'signature verification failed; refusing to install'
  log 'signature verification passed'

  need_root
  mkdir -p "$TARBALL_PREFIX" "$(dirname "$TARBALL_MANIFEST")"
  _stage="$_tmp/unpack"
  mkdir -p "$_stage"
  tar -xzf "$_tmp/$_asset" -C "$_stage" || die "could not unpack $_asset"
  _top="$_stage/reprobuild-$_ver-$_plat-$_arch"
  [ -d "$_top" ] || die "archive did not contain the expected top-level directory reprobuild-$_ver-$_plat-$_arch"

  # The archive tree goes in INTACT under $prefix/lib/reprobuild, as the
  # packages install it: its launchers find their loader at
  # "$(dirname "$0")/../lib". Its lib/ carries a bundled glibc and
  # libstdc++, and must never be spread into $prefix/lib itself, which
  # is on the default loader path of most distributions: every program
  # on the machine would start loading reprobuild's libc.
  _home="$TARBALL_PREFIX/lib/reprobuild"
  : > "$TARBALL_MANIFEST"
  rm -rf "$_home"
  mkdir -p "$_home" "$TARBALL_PREFIX/bin"
  for _sub in bin lib; do
    [ -d "$_top/$_sub" ] || continue
    cp -a "$_top/$_sub" "$_home/$_sub"
  done
  # Recorded as one directory, so --uninstall removes exactly it.
  printf '%s\n' "$_home" >> "$TARBALL_MANIFEST"
  for _c in "$_home/bin"/*; do
    _b="$(basename "$_c")"
    case "$_b" in .*|*.json) continue ;; esac
    [ -f "$_c" ] && [ -x "$_c" ] || continue
    printf '#!/bin/sh\nexec %s "$@"\n' "$_home/bin/$_b" > "$TARBALL_PREFIX/bin/$_b"
    chmod 0755 "$TARBALL_PREFIX/bin/$_b"
    # Record every installed path, so --uninstall removes exactly
    # these and never globs the prefix.
    printf '%s\n' "$TARBALL_PREFIX/bin/$_b" >> "$TARBALL_MANIFEST"
  done
  printf '%s\n' "$_ver" > "$(dirname "$TARBALL_MANIFEST")/version"
  log "tarball install complete under $TARBALL_PREFIX (manifest: $TARBALL_MANIFEST)"
  log 'NOTE: a tarball install does NOT receive native updates. Re-run this
installer, or switch to a repository install, to upgrade.'
}

remove_tarball() {
  if [ ! -f "$TARBALL_MANIFEST" ]; then
    log "no tarball install manifest at $TARBALL_MANIFEST; nothing to remove"
    return 0
  fi
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    # The one directory the manifest records is the intact archive tree.
    if [ -d "$_p" ]; then run rm -rf "$_p"; else run rm -f "$_p"; fi
  done < "$TARBALL_MANIFEST"
  run rm -f "$TARBALL_MANIFEST" "$(dirname "$TARBALL_MANIFEST")/version"
  log 'tarball install removed'
}

# ---------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------

uninstall_all() {
  need_root
  log "uninstalling via method=$method"
  case "$method" in
    apt)     remove_apt ;;
    dnf)     remove_dnf ;;
    pacman)  remove_pacman ;;
    tarball) remove_tarball ;;
    *) die "cannot uninstall with method=$method" ;;
  esac
  release_shared_entry
  _others="$(other_shared_users | tr '\n' ' ')"
  if [ -n "$_others" ]; then
    log "keeping the Metacraft Labs repository and key: still used by ${_others% }"
  else
    # The trust anchor goes too. Leaving it means an "uninstalled" machine
    # still trusts the signing key for anything that re-adds the repo,
    # which is not what a user who uninstalled asked for.
    run rm -f "$KEYRING_DEST"
    run rmdir "$REPO_USERS_DIR" 2>/dev/null || true
  fi
  # A tarball install alongside a package install is possible (someone
  # tried both); remove that record too rather than leaving a stale one.
  [ "$method" = 'tarball' ] || remove_tarball >/dev/null 2>&1 || true
  log 'uninstall complete'
}

# ---------------------------------------------------------------------
# main
# ---------------------------------------------------------------------

detect_distro
[ "$method" != 'auto' ] || method="$(detect_method)"

log "$PRODUCT installer: distro=$DISTRO_ID codename=${DISTRO_CODENAME:--} like=${DISTRO_LIKE:--} arch=$(uname -m) method=$method"
if [ -n "${REPRO_BASE_URL:-}" ]; then
  log "base URL override: REPRO_BASE_URL=$REPRO_BASE_URL"
fi

if [ "$do_uninstall" -eq 1 ]; then
  uninstall_all
  exit 0
fi

case "$method" in
  apt|dnf|pacman)
    need_root
    _tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_tmp'" EXIT INT TERM
    install_trust_anchor "$_tmp"
    claim_shared_entry
    case "$method" in
      apt)    register_apt;    install_apt ;;
      dnf)    register_dnf;    install_dnf ;;
      pacman) register_pacman; install_pacman ;;
    esac
    log "$PRODUCT installed from the native repository."
    log "Future upgrades come from your package manager (e.g. 'apt upgrade'), not from this script."
    ;;
  tarball)
    install_tarball
    ;;
  scoop)
    die 'method=scoop is the Windows path; run scripts/install/repro-install.ps1 under PowerShell.'
    ;;
  *)
    die "unsupported method: $method"
    ;;
esac

# The PACKAGE is `reprobuild`; the BINARY it installs is `repro`. Checking
# for a command named after the package would silently never fire.
REPRO_BIN="${REPRO_BIN_NAME:-repro}"
if [ "$dry_run" -eq 0 ] && command -v "$REPRO_BIN" >/dev/null 2>&1; then
  log "installed binary: $(command -v "$REPRO_BIN")"
  log "reported version: $("$REPRO_BIN" --version 2>/dev/null || echo 'version unavailable')"
fi
exit 0
