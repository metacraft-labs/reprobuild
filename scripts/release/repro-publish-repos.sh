#!/bin/sh
# Generate signed repository metadata and publish it. The release
# pipeline step for M3.
#
#   repro-publish-repos.sh --version 0.1.3 --packages <dir> --key <fpr> \
#       [--ecosystem deb|rpm|arch|all] [--repo-root <dir>] \
#       [--target <spec>] [--fetch-existing]
#
# ## The upload target is a VARIABLE, and why
#
# --target (or $REPRO_PUBLISH_TARGET) selects where the finished tree
# goes. Generating the metadata is a local, fully testable operation;
# pushing it to Cloudflare R2 needs credentials and a bucket that exist
# outside this repository, and reprobuild.com's DNS delegation was still
# in flight when this was written. Making the destination a parameter is
# what lets the gate publish to a local HTTP root and exercise the exact
# same generation path that production will use, instead of testing a
# different code path from the real one.
#
#   local:<path>          copy the tree to a directory (the gate)
#   s3://<bucket>/<pfx>   aws-cli; with $AWS_ENDPOINT_URL_S3 set this is R2
#   r2:<bucket>/<pfx>     rclone remote $REPRO_RCLONE_REMOTE (default r2)
#   none                  generate only, upload nothing
#
# ## Why the repository tree is STATEFUL, and what that means for upgrades
#
# `apt upgrade` can only move a user to a newer release if the repository
# offers BOTH: the index must list the new version, and the pool must
# still be a valid repository. So publishing 0.1.4 is not "write a new
# repo", it is "add 0.1.4 to the existing pool and regenerate the index
# over everything". That is why --fetch-existing exists: against a real
# R2 bucket the current pool must be pulled down before the new package
# is added, or publishing 0.1.4 would silently DELETE 0.1.3 and every
# pinned install would break.
#
# The metadata regeneration itself is M2's: repro-sign-apt-repo.sh,
# repro-sign-rpm-repo.sh, repro-sign-pacman-repo.sh. This script does not
# reimplement any signing. It arranges the pool, calls them, and uploads.

set -eu

PR_SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
SIGN_DIR="${REPRO_SIGN_DIR:-$PR_SELF_DIR/../release-signing}"

version=''; packages=''; key=''; ecosystem='all'
repo_root=''; target="${REPRO_PUBLISH_TARGET:-none}"
fetch_existing=0
suite="${REPRO_APT_SUITE:-stable}"
component="${REPRO_APT_COMPONENT:-main}"
deb_arch="${REPRO_DEB_ARCH:-amd64}"
arch_repo_name="${REPRO_ARCH_REPO_NAME:-reprobuild}"
# Must match the [section] id repro-install.sh writes into
# /etc/yum.repos.d/reprobuild.repo, or dnf reads config for a repo the
# metadata does not describe.
rpm_repo_id="${REPRO_RPM_REPO_ID:-reprobuild}"
# The base the Scoop manifest points at for the archive. Separate from the
# repo tree, because a Scoop manifest references the DOWNLOAD host, not
# the bucket it lives in.
scoop_downloads_base="${REPRO_SCOOP_DOWNLOADS_BASE:-https://downloads.reprobuild.com}"
scoop_homepage_domain="${REPRO_DOMAIN:-reprobuild.com}"
export_keyring=''

log() { printf 'repro-publish-repos: %s\n' "$*" >&2; }
die() { printf 'repro-publish-repos: ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)    version="$2"; shift 2 ;;
    --packages)   packages="$2"; shift 2 ;;
    --key)        key="$2"; shift 2 ;;
    --ecosystem)  ecosystem="$2"; shift 2 ;;
    --repo-root)  repo_root="$2"; shift 2 ;;
    --target)     target="$2"; shift 2 ;;
    --fetch-existing) fetch_existing=1; shift ;;
    --suite)      suite="$2"; shift 2 ;;
    --component)  component="$2"; shift 2 ;;
    --deb-arch)   deb_arch="$2"; shift 2 ;;
    --export-keyring) export_keyring="$2"; shift 2 ;;
    --scoop-downloads-base) scoop_downloads_base="$2"; shift 2 ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$version" ]  || die '--version is required'
[ -n "$packages" ] || die '--packages is required'
[ -d "$packages" ] || die "--packages $packages is not a directory"
[ -d "$SIGN_DIR" ] || die "signing scripts not found at $SIGN_DIR"

# A signing key is required only by the ecosystems that actually sign.
# apt/dnf/pacman metadata is OpenPGP-signed; a Scoop manifest is not --
# Scoop verifies artifact HASHES against the manifest, and there is no
# signature over the manifest itself. Demanding a signing key to emit a
# Scoop manifest would be theatre: it would be accepted and never used,
# which is worse than not asking, because it suggests a guarantee the
# Windows path does not have. See repro-install.ps1 for the same point
# stated to the user.
needs_signing_key=0
case "$ecosystem" in
  all|deb|rpm|arch) needs_signing_key=1 ;;
esac
[ -z "$export_keyring" ] || needs_signing_key=1

if [ "$needs_signing_key" -eq 1 ]; then
  [ -n "$key" ] || die "--key is required to publish '$ecosystem' (its metadata is signed)"
  [ -n "${GNUPGHOME:-}" ] || die 'GNUPGHOME must point at the home holding the signing key.
This script will not fall back to ~/.gnupg: gpg is stateful, and a
publish that signed with whatever key the operator happened to trust is
how an unsigned-in-practice repository gets shipped.'
else
  log "ecosystem '$ecosystem' signs nothing; no signing key required"
fi

packages="$(CDPATH='' cd -- "$packages" && pwd)"
if [ -z "$repo_root" ]; then
  repo_root="$(mktemp -d)"
  log "no --repo-root given; using $repo_root"
fi
mkdir -p "$repo_root"
repo_root="$(CDPATH='' cd -- "$repo_root" && pwd)"

want() {
  case "$ecosystem" in
    all) return 0 ;;
    "$1") return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------
# target plumbing
# ---------------------------------------------------------------------

# Parse the target once so an unsupported scheme fails BEFORE any signing
# happens. Discovering a bad target after publishing leaves a signed tree
# nobody fetched and an operator who thinks they shipped.
target_scheme=''
target_rest=''
case "$target" in
  none)      target_scheme='none' ;;
  local:*)   target_scheme='local'; target_rest="${target#local:}" ;;
  s3://*)    target_scheme='s3';    target_rest="$target" ;;
  r2:*)      target_scheme='r2';    target_rest="${target#r2:}" ;;
  *) die "unsupported --target '$target' (want local:<path>, s3://<bucket>/<prefix>, r2:<bucket>/<prefix>, or none)" ;;
esac
log "publish target: scheme=$target_scheme rest=${target_rest:-(none)}"

# Pull the CURRENT published tree down, so that adding a version is
# additive. Without this, publishing is destructive and `apt upgrade`
# would work exactly once.
fetch_existing_tree() {
  _dest="$1"; _sub="$2"
  case "$target_scheme" in
    none) log "no target; nothing to fetch (pool starts empty)" ;;
    local)
      if [ -d "$target_rest/$_sub" ]; then
        log "fetching existing tree from $target_rest/$_sub"
        mkdir -p "$_dest"
        ( cd "$target_rest/$_sub" && tar -cf - . ) | ( cd "$_dest" && tar -xf - )
      else
        log "no existing tree at $target_rest/$_sub (first publish)"
      fi
      ;;
    s3)
      command -v aws >/dev/null 2>&1 || die 'aws cli not found; needed to fetch the existing tree'
      mkdir -p "$_dest"
      log "aws s3 sync ${target_rest%/}/$_sub -> $_dest"
      aws s3 sync "${target_rest%/}/$_sub" "$_dest" || die 'aws s3 sync (download) failed'
      ;;
    r2)
      command -v rclone >/dev/null 2>&1 || die 'rclone not found; needed to fetch the existing tree'
      _remote="${REPRO_RCLONE_REMOTE:-r2}"
      mkdir -p "$_dest"
      log "rclone copy $_remote:${target_rest%/}/$_sub -> $_dest"
      rclone copy "$_remote:${target_rest%/}/$_sub" "$_dest" || die 'rclone copy (download) failed'
      ;;
  esac
}

upload_tree() {
  _src="$1"; _sub="$2"
  case "$target_scheme" in
    none) log "target=none: generated $_sub under $_src, uploaded nothing" ;;
    local)
      log "publishing $_sub -> $target_rest/$_sub"
      mkdir -p "$target_rest/$_sub"
      ( cd "$_src" && tar -cf - . ) | ( cd "$target_rest/$_sub" && tar -xf - ) \
        || die "local publish of $_sub failed"
      ;;
    s3)
      command -v aws >/dev/null 2>&1 || die 'aws cli not found'
      # --delete is deliberately ABSENT. A sync that deletes would remove
      # older pool packages the moment a publish ran from a tree that had
      # not fetched them, breaking every pinned install. Pruning old
      # versions is a separate, deliberate operation.
      log "aws s3 sync $_src -> ${target_rest%/}/$_sub"
      aws s3 sync "$_src" "${target_rest%/}/$_sub" || die "aws s3 sync (upload) of $_sub failed"
      ;;
    r2)
      command -v rclone >/dev/null 2>&1 || die 'rclone not found'
      _remote="${REPRO_RCLONE_REMOTE:-r2}"
      log "rclone copy $_src -> $_remote:${target_rest%/}/$_sub"
      rclone copy "$_src" "$_remote:${target_rest%/}/$_sub" \
        || die "rclone copy (upload) of $_sub failed"
      ;;
  esac
}

count_files() {
  find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------
# apt
# ---------------------------------------------------------------------
publish_deb() {
  _root="$repo_root/deb"
  mkdir -p "$_root/pool/$component"
  [ "$fetch_existing" -eq 0 ] || fetch_existing_tree "$_root" deb

  _n=0
  for _d in "$packages"/*.deb; do
    [ -f "$_d" ] || continue
    cp "$_d" "$_root/pool/$component/"
    _n=$((_n + 1))
  done
  [ "$_n" -gt 0 ] || die "no .deb in $packages"
  _pool_total="$(find "$_root/pool" -name '*.deb' | wc -l | tr -d ' ')"
  log "apt pool: added $_n, total $_pool_total .deb"

  # Regenerate the index over the WHOLE pool and re-sign. M2's script
  # uses dpkg-scanpackages --multiversion, so every version in the pool
  # is listed -- which is what makes `apt install pkg=<old>` and
  # `apt upgrade` both work off one index.
  _args=''
  [ -z "$export_keyring" ] || _args="--export-key $export_keyring"
  # shellcheck disable=SC2086
  sh "$SIGN_DIR/repro-sign-apt-repo.sh" \
      --root "$_root" --key "$key" \
      --suite "$suite" --component "$component" --arch "$deb_arch" $_args \
    || die 'repro-sign-apt-repo.sh failed'

  # Assert the new version really made it into the index. dpkg-scanpackages
  # skips a .deb it cannot parse and still exits 0, which would publish an
  # index that silently lacks the release being shipped -- and then
  # `apt upgrade` would find nothing and the pipeline would look green.
  _pkgs="$_root/dists/$suite/$component/binary-$deb_arch/Packages"
  [ -f "$_pkgs" ] || die "no Packages index generated at $_pkgs"
  _hits="$(grep -c "^Version: $version" "$_pkgs" || true)"
  [ "${_hits:-0}" -ge 1 ] \
    || die "the generated Packages index contains no 'Version: $version' stanza.
dpkg-scanpackages exits 0 when it skips an unparsable .deb, so this is
checked rather than assumed. Index has $(grep -c '^Package:' "$_pkgs" || echo 0) stanza(s)."
  log "apt index lists Version: $version ($_hits stanza(s))"

  upload_tree "$_root" deb
}

# ---------------------------------------------------------------------
# rpm
# ---------------------------------------------------------------------
publish_rpm() {
  _root="$repo_root/rpm"
  mkdir -p "$_root"
  [ "$fetch_existing" -eq 0 ] || fetch_existing_tree "$_root" rpm

  _n=0
  for _r in "$packages"/*.rpm; do
    [ -f "$_r" ] || continue
    cp "$_r" "$_root/"
    _n=$((_n + 1))
  done
  [ "$_n" -gt 0 ] || die "no .rpm in $packages"
  log "rpm repo: added $_n, total $(find "$_root" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ') .rpm"

  _args=''
  [ -z "$export_keyring" ] || _args="--export-key $export_keyring"
  # shellcheck disable=SC2086
  sh "$SIGN_DIR/repro-sign-rpm-repo.sh" \
      --root "$_root" --key "$key" --id "$rpm_repo_id" $_args \
    || die 'repro-sign-rpm-repo.sh failed'

  [ -f "$_root/repodata/repomd.xml" ] || die 'createrepo_c produced no repodata/repomd.xml'
  [ -f "$_root/repodata/repomd.xml.asc" ] || die 'repomd.xml was not signed'
  _hits="$(grep -c -- "$version" "$_root"/repodata/*primary* 2>/dev/null || true)"
  log "rpm metadata references version $version ($_hits match(es) in primary metadata)"

  upload_tree "$_root" rpm
}

# ---------------------------------------------------------------------
# pacman
# ---------------------------------------------------------------------
publish_arch() {
  _root="$repo_root/arch"
  mkdir -p "$_root"
  [ "$fetch_existing" -eq 0 ] || fetch_existing_tree "$_root" arch

  _n=0
  for _p in "$packages"/*.pkg.tar.zst; do
    [ -f "$_p" ] || continue
    cp "$_p" "$_root/"
    _n=$((_n + 1))
  done
  [ "$_n" -gt 0 ] || die "no .pkg.tar.zst in $packages"
  log "pacman repo: added $_n package(s)"

  _args=''
  [ -z "$export_keyring" ] || _args="--export-key $export_keyring"
  # shellcheck disable=SC2086
  # M2's flag is --db (the pacman database NAME, which becomes
  # <name>.db.tar.gz and must match the [section] the installer writes).
  sh "$SIGN_DIR/repro-sign-pacman-repo.sh" \
      --root "$_root" --key "$key" --db "$arch_repo_name" $_args \
    || die 'repro-sign-pacman-repo.sh failed'

  upload_tree "$_root" arch
}

# ---------------------------------------------------------------------
# scoop (Windows)
# ---------------------------------------------------------------------
# A Scoop bucket is a git repository containing bucket/<app>.json. The
# manifest carries the artifact URL and its sha256, and Scoop refuses a
# download whose hash does not match -- on install AND on every update.
#
# The URL is built from the SAME --target-independent base used
# everywhere else, and the hash is COMPUTED from the artifact rather than
# left as a placeholder. runquota's packaging leaves `@SCOOP_URL@` in its
# manifest because no bucket exists to publish to; here the URL is a
# variable instead, so the manifest that the gate installs from and the
# manifest production publishes differ only in that variable's value.
# A manifest with an unsubstituted token is refused below, because such a
# manifest makes `scoop install` fetch nothing -- and only after a user
# tried.
publish_scoop() {
  _root="$repo_root/scoop"
  mkdir -p "$_root/bucket"
  [ "$fetch_existing" -eq 0 ] || fetch_existing_tree "$_root" scoop

  _zip=''
  for _z in "$packages"/*.zip; do
    [ -f "$_z" ] || continue
    _zip="$_z"
    break
  done
  [ -n "$_zip" ] || die "no .zip in $packages (the Windows release asset); cannot write a Scoop manifest"
  _zipname="$(basename "$_zip")"
  _hash="$(sha256sum "$_zip" | awk '{print $1}')"
  _url="${REPRO_DOWNLOADS_BASE:-$scoop_downloads_base}/v$version/$_zipname"

  # `bin` uses backslashes: Scoop shims are Windows paths inside the
  # extracted directory.
  cat > "$_root/bucket/reprobuild.json" <<MANIFEST
{
  "version": "$version",
  "description": "Reprobuild — a reproducible build system",
  "homepage": "https://$scoop_homepage_domain",
  "license": "Apache-2.0",
  "architecture": {
    "64bit": {
      "url": "$_url",
      "hash": "sha256:$_hash"
    }
  },
  "extract_dir": "reprobuild-$version-windows-x86_64",
  "bin": [
    "bin\\\\repro.exe"
  ],
  "checkver": {
    "url": "https://api.github.com/repos/metacraft-labs/reprobuild/releases/latest",
    "jsonpath": "\$.tag_name",
    "regex": "v([\\\\d.]+)"
  }
}
MANIFEST

  # A manifest carrying an unsubstituted token would install nothing.
  if grep -q '@SCOOP_URL@\|@SCOOP_SHA256@' "$_root/bucket/reprobuild.json"; then
    die 'the generated Scoop manifest still carries a publish placeholder'
  fi
  # And one whose hash is not a real digest is equally useless.
  _n="$(grep -c '"hash": "sha256:[0-9a-f]\{64\}"' "$_root/bucket/reprobuild.json" || true)"
  [ "${_n:-0}" -eq 1 ] \
    || die "the generated Scoop manifest does not carry exactly one sha256 hash (found ${_n:-0})"
  log "scoop manifest: version=$version hash=$_hash"
  log "scoop manifest url: $_url"

  upload_tree "$_root" scoop
}

# ---------------------------------------------------------------------
# the keys surface
# ---------------------------------------------------------------------
# The trust anchor is published to its OWN prefix, never beside the
# release artifacts. Verifying a release against a key fetched from the
# same place is circular; see docs/release-signing.md.
publish_keys() {
  [ -n "$export_keyring" ] || { log 'no --export-keyring; not publishing a keys/ surface'; return 0; }
  [ -f "$export_keyring" ] || die "--export-keyring $export_keyring was not produced"
  _root="$repo_root/keys"
  mkdir -p "$_root"
  cp "$export_keyring" "$_root/reprobuild-archive-keyring.gpg"
  # The digest the installer pins. Printed so the value that must be
  # baked into repro-install.sh comes from the artifact, not from a human
  # retyping it.
  if command -v sha256sum >/dev/null 2>&1; then
    _sum="$(sha256sum "$_root/reprobuild-archive-keyring.gpg" | awk '{print $1}')"
    printf '%s\n' "$_sum" > "$_root/reprobuild-archive-keyring.gpg.sha256"
    log "TRUST ANCHOR sha256 = $_sum"
    log "  ^ this is the value REPRO_KEYRING_SHA256 must carry in scripts/install/repro-install.sh"
  fi
  upload_tree "$_root" keys
}

published=0
if want deb;  then publish_deb;  published=$((published + 1)); fi
if want rpm;  then publish_rpm;  published=$((published + 1)); fi
if want arch; then publish_arch; published=$((published + 1)); fi
if want scoop; then publish_scoop; published=$((published + 1)); fi
[ "$published" -gt 0 ] || die "--ecosystem $ecosystem selected nothing to publish"
publish_keys

log "published $published ecosystem(s) for version $version"
log "repo root: $repo_root ($(count_files "$repo_root") files)"
