#!/bin/sh
# Generate signed repository metadata and publish it. The release
# pipeline step for M3.
#
#   repro-publish-repos.sh --version 0.1.3 --packages <dir> --key <fpr> \
#       [--ecosystem deb|rpm|arch|downloads|scoop|homebrew|all] \
#       [--repo-root <dir>] [--archives <dir>] \
#       [--target <spec>] [--target-<surface> <spec>] [--fetch-existing]
#
# ## SEVEN SURFACES, FIVE BUCKETS, AND ONE --target THAT CANNOT REACH THEM
#
# This script publishes seven surfaces:
#
#   deb rpm arch downloads keys      -- object stores
#   scoop homebrew                   -- git repositories
#
# `infra`'s terraform/cloudflare/reprobuild-prod provisions FIVE R2 buckets,
# `reprobuild-{deb,rpm,arch,downloads,keys}-prod`, each bound to one hostname
# by an R2 custom domain and therefore served at the ROOT of that hostname:
# `deb.reprobuild.com/dists/stable/InRelease` needs a bucket whose key
# `dists/stable/InRelease` is at its root. One `--target` writing six prefixes
# under one destination cannot address five roots, and it never could.
#
# So the destination is now resolved PER SURFACE:
#
#   --target-deb / --target-rpm / --target-arch / --target-downloads /
#   --target-keys / --target-scoop / --target-homebrew
#     (or $REPRO_PUBLISH_TARGET_DEB, ..._RPM, ..._ARCH, ..._DOWNLOADS,
#      ..._KEYS, ..._SCOOP, ..._HOMEBREW)
#
# and production passes five bucket roots:
#
#   --target-deb       r2:reprobuild-deb-prod
#   --target-rpm       r2:reprobuild-rpm-prod
#   --target-arch      r2:reprobuild-arch-prod
#   --target-downloads r2:reprobuild-downloads-prod
#   --target-keys      r2:reprobuild-keys-prod
#
# `--target` (or $REPRO_PUBLISH_TARGET) remains, and remains the thing the
# gate uses: with no per-surface override it DERIVES one destination per
# surface by appending the surface name as a prefix. That is what
# `scripts/install/repro-install.sh` already expects from its $REPRO_BASE_URL
# mode -- `$base/deb`, `$base/rpm`, `$base/arch`, `$base/downloads`,
# `$base/keys` -- and it is the exact behaviour this script had before, so
# every existing invocation is unchanged.
#
#   local:<path>          copy the tree to a directory (the gate)
#   s3://<bucket>/<pfx>   aws-cli; with $AWS_ENDPOINT_URL_S3 set this is R2
#   r2:<bucket>/<pfx>     rclone remote $REPRO_RCLONE_REMOTE (default r2)
#   git:<url>[#<branch>]  clone, replace, commit, push -- for scoop/homebrew
#   none                  generate only, upload nothing
#
# ## `scoop` had a prefix and no bucket; `downloads` had a bucket and no
# ## prefix. Both of those were wrong, and in opposite directions.
#
# DOWNLOADS. `repro-install.sh --method tarball` fetches
# `$REPRO_DOWNLOADS_URL/v<version>/<asset>`, `/SHA256SUMS`,
# `/SHA256SUMS.asc` and `/<asset>.asc`. Terraform provisions the bucket and
# the hostname for exactly that. Nothing wrote it: the release archives went
# to the GitHub release and nowhere else, so in production the repo-less
# install path would have 404'd on an empty bucket. `--archives <dir>`
# (release.yml's `staging/`) closes it; see `publish_downloads`.
#
# SCOOP. A Scoop bucket is a GIT REPOSITORY -- `scoop bucket add` clones it --
# and R2 serves objects, not git. There is no `scoop` bucket in terraform and
# there must not be one: an R2 prefix full of `bucket/reprobuild.json` is a
# tree no Scoop client can consume. The same is true of a Homebrew tap
# (`brew tap` clones). So the generic `--target` does NOT fan out to these two
# when it names an object store; see `resolve_surface_target`.
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
archives=''
fetch_existing=0

# Per-surface destinations. Empty means "derive from --target"; see
# `resolve_surface_target`, which is the only place the derivation rule lives.
target_deb="${REPRO_PUBLISH_TARGET_DEB:-}"
target_rpm="${REPRO_PUBLISH_TARGET_RPM:-}"
target_arch="${REPRO_PUBLISH_TARGET_ARCH:-}"
target_downloads="${REPRO_PUBLISH_TARGET_DOWNLOADS:-}"
target_keys="${REPRO_PUBLISH_TARGET_KEYS:-}"
target_scoop="${REPRO_PUBLISH_TARGET_SCOOP:-}"
target_homebrew="${REPRO_PUBLISH_TARGET_HOMEBREW:-}"

# The git repositories the two git-backed surfaces live in. NEITHER EXISTS.
# They are named here rather than only in `infra`'s `git_backed_surfaces`
# terraform output because that output renders only under `tofu output`, which
# needs credentials this root will not have until it is applied -- so the one
# place the gap was recorded was a place nobody running a release would look.
# This script prints the prerequisite on every run that reaches one of them --
# INCLUDING the runs where the surface generates nothing at all, which is where
# the announcement used to be lost and is the only output such a run has.
scoop_bucket_repo="${REPRO_SCOOP_BUCKET_REPO:-https://github.com/metacraft-labs/scoop-reprobuild}"
homebrew_tap_repo="${REPRO_HOMEBREW_TAP_REPO:-https://github.com/metacraft-labs/homebrew-reprobuild}"
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
    --target-deb)       target_deb="$2"; shift 2 ;;
    --target-rpm)       target_rpm="$2"; shift 2 ;;
    --target-arch)      target_arch="$2"; shift 2 ;;
    --target-downloads) target_downloads="$2"; shift 2 ;;
    --target-keys)      target_keys="$2"; shift 2 ;;
    --target-scoop)     target_scoop="$2"; shift 2 ;;
    --target-homebrew)  target_homebrew="$2"; shift 2 ;;
    --archives)   archives="$2"; shift 2 ;;
    --fetch-existing) fetch_existing=1; shift ;;
    --suite)      suite="$2"; shift 2 ;;
    --component)  component="$2"; shift 2 ;;
    --deb-arch)   deb_arch="$2"; shift 2 ;;
    --export-keyring) export_keyring="$2"; shift 2 ;;
    --scoop-downloads-base) scoop_downloads_base="$2"; shift 2 ;;
    -h|--help)    sed -n '2,113p' "$0"; exit 0 ;;
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

# Which surfaces are object stores and which are git repositories. This is
# not a style distinction: `scoop bucket add` and `brew tap` CLONE, and an R2
# bucket cannot serve git, so pushing a Scoop bucket to an object store
# produces a tree that looks published and that no client can consume.
git_backed_surface() {
  case "$1" in
    scoop|homebrew) return 0 ;;
    *) return 1 ;;
  esac
}

surface_repo() {
  case "$1" in
    scoop)    printf '%s' "$scoop_bucket_repo" ;;
    homebrew) printf '%s' "$homebrew_tap_repo" ;;
  esac
}

# The per-surface override, or empty.
surface_override() {
  case "$1" in
    deb)       printf '%s' "$target_deb" ;;
    rpm)       printf '%s' "$target_rpm" ;;
    arch)      printf '%s' "$target_arch" ;;
    downloads) printf '%s' "$target_downloads" ;;
    keys)      printf '%s' "$target_keys" ;;
    scoop)     printf '%s' "$target_scoop" ;;
    homebrew)  printf '%s' "$target_homebrew" ;;
    *) die "surface_override: unknown surface '$1'" ;;
  esac
}

# THE DERIVATION RULE, in one place.
#
# An explicit per-surface target wins outright -- that is how production
# addresses five bucket ROOTS, each served at the root of its own hostname.
#
# Otherwise the generic --target is extended with the surface name as a
# prefix, which is byte-for-byte what this script did before and what
# repro-install.sh's $REPRO_BASE_URL mode expects.
#
# THE ONE EXCEPTION, and the whole point of item 4: a git-backed surface is
# NEVER derived from an object-store --target. `local:` is derived (a
# directory tree IS a legitimate Scoop bucket source -- the M3 gate git-inits
# the published directory and adds it, which is what a bucket is), and `none`
# is derived trivially. `s3:` and `r2:` resolve to `none` instead, so the
# manifest is generated and STAGED and the prerequisite is printed, rather
# than uploaded somewhere no client can clone.
#
# Resolving to `none` rather than dying is deliberate. Dying here would take
# the whole publish step with it -- including the trust anchor, which is the
# thing that is currently blocked -- on account of a repository that does not
# exist yet. Fail-closed for the git surfaces means "publish nothing and say
# so loudly", not "publish nothing else either".
resolve_surface_target() {
  _s="$1"
  _o="$(surface_override "$_s")"
  if [ -n "$_o" ]; then printf '%s' "$_o"; return 0; fi
  case "$target_scheme" in
    none)  printf 'none' ;;
    local) printf 'local:%s/%s' "${target_rest%/}" "$_s" ;;
    s3|r2)
      if git_backed_surface "$_s"; then
        printf 'none'
      elif [ "$target_scheme" = s3 ]; then
        printf '%s/%s' "${target_rest%/}" "$_s"
      else
        printf 'r2:%s/%s' "${target_rest%/}" "$_s"
      fi
      ;;
  esac
}

# Parse a target spec into $ts_scheme / $ts_rest. Every spec -- the generic
# one and every per-surface one -- goes through this, up front, so an
# unsupported scheme fails BEFORE any signing happens. Discovering a bad
# target after publishing leaves a signed tree nobody fetched and an operator
# who thinks they shipped.
ts_scheme=''
ts_rest=''
parse_target_spec() {
  case "$1" in
    none)      ts_scheme='none';  ts_rest='' ;;
    local:*)   ts_scheme='local'; ts_rest="${1#local:}" ;;
    s3://*)    ts_scheme='s3';    ts_rest="$1" ;;
    r2:*)      ts_scheme='r2';    ts_rest="${1#r2:}" ;;
    git:*)     ts_scheme='git';   ts_rest="${1#git:}" ;;
    *) die "unsupported target '$1' (want local:<path>, s3://<bucket>/<prefix>, r2:<bucket>/<prefix>, git:<url>[#<branch>], or none)" ;;
  esac
}

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

# Resolve and VALIDATE every surface before anything is signed or copied.
# A bad per-surface spec discovered halfway through leaves some surfaces
# published and some not, which for a stateful repository is worse than not
# starting: the index and the pool would disagree about what exists.
for _surface in deb rpm arch downloads keys scoop homebrew; do
  _spec="$(resolve_surface_target "$_surface")"
  parse_target_spec "$_spec"
  if git_backed_surface "$_surface"; then
    case "$ts_scheme" in
      s3|r2)
        die "--target-$_surface was given '$_spec', but $_surface is a GIT
repository, not an object store: \`scoop bucket add\` and \`brew tap\` clone it.
An object store cannot serve git, so this would publish a tree that looks
right and that no client can consume. Use git:<url>, local:<path>, or none."
        ;;
    esac
  else
    case "$ts_scheme" in
      git)
        die "--target-$_surface was given '$_spec', but $_surface is a repository
tree served over HTTP, not a git remote. Use local:, s3://, r2: or none."
        ;;
    esac
  fi
  log "  surface $_surface -> $_spec"
done

# ---------------------------------------------------------------------
# what a surface actually DID
# ---------------------------------------------------------------------
#
# Three surfaces can legitimately publish nothing: a git-backed surface whose
# repository does not exist yet resolves to `none`, `homebrew` skips a release
# that carries no macOS archive, and `downloads` skips when no `--archives` is
# passed. Counting those as published overstates what shipped: on both releases
# so far the final line read `published 6 ecosystem(s)` while two of the six
# had moved no bytes at all.
#
# So each surface records an outcome, the tally counts only the ones that
# published, and the no-ops are PRINTED with their reasons rather than dropped
# from the output -- a channel that published nothing is the thing an operator
# most needs to see, so it must get louder, not quieter.
surface_result='published'
surface_result_reason=''

surface_noop() {
  surface_result='noop'
  surface_result_reason="$1"
}

# ---------------------------------------------------------------------
# the URL a client is pointed at
# ---------------------------------------------------------------------
#
# THE VERSION SEGMENT IS OWNED HERE, AND ONLY HERE.
#
# `--scoop-downloads-base` (or $REPRO_DOWNLOADS_BASE) names the ROOT that the
# per-release directory hangs under, and `v<version>/` is appended to it. That
# is not an arbitrary convention: it is what `scripts/install/repro-install.sh`
# fetches (`$REPRO_DOWNLOADS_URL/v<version>/<asset>`, install_tarball), and it
# is the layout `publish_downloads` writes into the downloads bucket. The two
# roots that are actually used both take it:
#
#   https://downloads.reprobuild.com                       -> /v0.1.3/<asset>
#   https://github.com/<owner>/<repo>/releases/download    -> /v0.1.3/<asset>
#
# and for GitHub the appended `v<version>` IS the release tag, which is exactly
# what a release-asset URL carries.
#
# A base that already ends in the version therefore yields
# `.../download/v0.1.3/v0.1.3/<asset>` -- a URL shaped like a URL that 404s.
# release.yml passed such a base, so every Scoop manifest ever generated
# carried a dead link, and the Homebrew formula inherited the same base and the
# same dead link the moment it started using it. Refused here rather than
# published, so the defect cannot come back through the other end.
downloads_asset_url() {
  _base="${REPRO_DOWNLOADS_BASE:-$scoop_downloads_base}"
  _base="${_base%/}"
  case "$_base" in
    *"/v$version")
      die "the downloads base '$_base' already ends in the version segment
'v$version', and this script appends '/v$version/<asset>' to it. The result
would be '$_base/v$version/<asset>', which 404s for every client that reads it
-- \`scoop install\`, \`brew install\`, and repro-install.sh --method tarball
alike. Pass the ROOT the per-release directory hangs under instead:
  --scoop-downloads-base https://downloads.reprobuild.com
  --scoop-downloads-base https://github.com/<owner>/<repo>/releases/download"
      ;;
  esac
  printf '%s/v%s/%s' "$_base" "$version" "$1"
}

# Pull the CURRENT published tree down, so that adding a version is
# additive. Without this, publishing is destructive and `apt upgrade`
# would work exactly once.
fetch_existing_tree() {
  _dest="$1"; _sub="$2"
  parse_target_spec "$(resolve_surface_target "$_sub")"
  case "$ts_scheme" in
    none) log "$_sub: no target; nothing to fetch (pool starts empty)" ;;
    local)
      if [ -d "$ts_rest" ]; then
        log "fetching existing $_sub tree from $ts_rest"
        mkdir -p "$_dest"
        ( cd "$ts_rest" && tar -cf - . ) | ( cd "$_dest" && tar -xf - )
      else
        log "no existing tree at $ts_rest (first publish of $_sub)"
      fi
      ;;
    s3)
      command -v aws >/dev/null 2>&1 || die 'aws cli not found; needed to fetch the existing tree'
      mkdir -p "$_dest"
      log "aws s3 sync ${ts_rest%/} -> $_dest"
      aws s3 sync "${ts_rest%/}" "$_dest" || die 'aws s3 sync (download) failed'
      ;;
    r2)
      command -v rclone >/dev/null 2>&1 || die 'rclone not found; needed to fetch the existing tree'
      _remote="${REPRO_RCLONE_REMOTE:-r2}"
      mkdir -p "$_dest"
      log "rclone copy $_remote:${ts_rest%/} -> $_dest"
      rclone copy "$_remote:${ts_rest%/}" "$_dest" || die 'rclone copy (download) failed'
      ;;
    git)
      # The clone IS the fetch: a git-backed surface is stateful in exactly
      # the same way the apt pool is, and a push that discarded history would
      # break `scoop update` for everyone pinned to it.
      command -v git >/dev/null 2>&1 || die 'git not found; needed to fetch the existing git-backed surface'
      _url="${ts_rest%%#*}"
      _branch=''
      case "$ts_rest" in *\#*) _branch="${ts_rest#*#}" ;; esac
      mkdir -p "$_dest"
      log "git clone $_url${_branch:+ (branch $_branch)} -> $_dest"
      # shellcheck disable=SC2086
      git clone --depth 1 ${_branch:+--branch "$_branch"} "$_url" "$_dest.git" \
        || die "git clone of $_url failed. If the repository does not exist yet, see the PREREQUISITE note above."
      ( cd "$_dest.git" && tar -cf - --exclude=.git . ) | ( cd "$_dest" && tar -xf - )
      rm -rf "$_dest.git"
      ;;
  esac
}

upload_tree() {
  _src="$1"; _sub="$2"
  parse_target_spec "$(resolve_surface_target "$_sub")"
  case "$ts_scheme" in
    none)
      if git_backed_surface "$_sub"; then
        announce_git_surface_prerequisite "$_sub" "$_src"
        surface_noop "no git remote configured; $(surface_repo "$_sub") does not exist yet"
      else
        log "$_sub: target=none; generated under $_src, uploaded nothing"
        surface_noop 'target=none; generated but uploaded nothing'
      fi
      ;;
    local)
      log "publishing $_sub -> $ts_rest"
      mkdir -p "$ts_rest"
      ( cd "$_src" && tar -cf - . ) | ( cd "$ts_rest" && tar -xf - ) \
        || die "local publish of $_sub failed"
      ;;
    s3)
      command -v aws >/dev/null 2>&1 || die 'aws cli not found'
      # --delete is deliberately ABSENT. A sync that deletes would remove
      # older pool packages the moment a publish ran from a tree that had
      # not fetched them, breaking every pinned install. Pruning old
      # versions is a separate, deliberate operation.
      log "aws s3 sync $_src -> ${ts_rest%/}"
      aws s3 sync "$_src" "${ts_rest%/}" || die "aws s3 sync (upload) of $_sub failed"
      ;;
    r2)
      command -v rclone >/dev/null 2>&1 || die 'rclone not found'
      _remote="${REPRO_RCLONE_REMOTE:-r2}"
      log "rclone copy $_src -> $_remote:${ts_rest%/}"
      rclone copy "$_src" "$_remote:${ts_rest%/}" \
        || die "rclone copy (upload) of $_sub failed"
      ;;
    git)
      publish_git_surface "$_src" "$_sub" "$ts_rest"
      ;;
  esac
}

# ---------------------------------------------------------------------
# the git-backed surfaces
# ---------------------------------------------------------------------
#
# A Scoop bucket and a Homebrew tap are git repositories that clients CLONE.
# Publishing one means committing the generated manifest and pushing, not
# copying objects into a store.
#
# `metacraft-labs/scoop-reprobuild` and `metacraft-labs/homebrew-reprobuild`
# DO NOT EXIST. Creating a GitHub repository is not this script's to do, and
# it is not the release pipeline's either -- it is a one-off act by a human
# with organisation rights. So this script is built right up to that boundary:
# it generates the artifact, it can push it the moment a remote is named, and
# when no remote is named it says -- on every single run that reaches this
# surface, in the release log, not in a terraform output nobody will run --
# exactly which repository has to exist and exactly what to pass once it does.
#
# "every run that reaches this surface" was, until this change, a weaker claim
# than it reads. `upload_tree` is the ONLY caller of this function, and
# `publish_homebrew` returned before `upload_tree` whenever the release carried
# no macOS archive -- which is every release shipped so far. So the surface
# whose repository is missing announced nothing on exactly the runs where the
# announcement was the only output it had. `publish_homebrew` now announces on
# that path too; see the skip branch there.
announce_git_surface_prerequisite() {
  _surface="$1"; _src="$2"
  _repo="$(surface_repo "$_surface")"
  _note="$_src/PUBLISH-THIS-SURFACE.md"
  cat > "$_note" <<PREREQ
# This tree is not published, and here is what it needs

\`$_surface\` is a **git repository**, not an object store: clients clone it
(\`scoop bucket add\`, \`brew tap\`). An R2 bucket cannot serve git, which is why
\`infra\`'s terraform/cloudflare/reprobuild-prod provisions no bucket for it.

The repository this tree belongs in is:

    $_repo

**It does not exist yet.** Somebody with rights in the \`metacraft-labs\`
organisation has to create it; nothing in this pipeline can, and nothing in
this pipeline should. Until then this tree is generated and left here.

Once it exists, publish by re-running the release step with:

    --target-$_surface git:$_repo

(or by setting \$REPRO_PUBLISH_TARGET_$(printf '%s' "$_surface" | tr '[:lower:]' '[:upper:]') in the workflow.)
PREREQ
  log "PREREQUISITE: $_surface is a git repository and none is configured."
  log "PREREQUISITE:   needs $_repo -- which DOES NOT EXIST YET."
  log "PREREQUISITE:   create it, then pass --target-$_surface git:$_repo"
  log "PREREQUISITE:   the generated tree and this note are at $_src"
  # A machine-readable line for release.yml to turn into a ::warning::, so the
  # gap lands where a human doing a release actually looks.
  printf 'REPRO_PUBLISH_PREREQUISITE\t%s\t%s\n' "$_surface" "$_repo"
}

# A surface that produced NOTHING for a reason that is not the missing
# repository.
#
# Deliberately a DIFFERENT announcement from the prerequisite above, not the
# same text reused. "homebrew was skipped because this release carries no macOS
# archive" and "homebrew needs a repository that does not exist yet" are
# different facts, with different owners and different remedies: the first is a
# property of this release's artifact set and is fixed by building a macOS
# archive; the second is a one-off act by somebody with rights in the
# `metacraft-labs` organisation. A release can have both at once -- every
# release so far did -- so on that release both are printed, and neither
# substitutes for the other.
announce_surface_skipped() {
  _surface="$1"; _why="$2"
  log "SKIPPED: $_surface published nothing for $version: $_why"
  # Its own marker, so release.yml renders its own ::warning:: with its own
  # remedy rather than mislabelling a shape problem as a missing repository.
  printf 'REPRO_PUBLISH_SKIPPED\t%s\t%s\n' "$_surface" "$_why"
}

publish_git_surface() {
  _src="$1"; _surface="$2"; _spec="$3"
  command -v git >/dev/null 2>&1 || die 'git not found; needed to publish a git-backed surface'
  _url="${_spec%%#*}"
  _branch=''
  case "$_spec" in *\#*) _branch="${_spec#*#}" ;; esac
  _work="$(mktemp -d)"
  log "publishing $_surface -> $_url${_branch:+ (branch $_branch)}"
  # shellcheck disable=SC2086
  git clone ${_branch:+--branch "$_branch"} "$_url" "$_work" \
    || die "git clone of $_url failed. If the repository does not exist yet, create it first -- see PUBLISH-THIS-SURFACE.md in the staged tree."
  # Replace the tracked content wholesale, then let git work out the diff.
  # Deleting and re-adding is what makes a REMOVED manifest actually
  # disappear; a copy-over-the-top publish can only ever add.
  ( cd "$_work" && git rm -r --quiet --ignore-unmatch . ) || true
  ( cd "$_src" && tar -cf - --exclude=PUBLISH-THIS-SURFACE.md . ) | ( cd "$_work" && tar -xf - )

  # WHO THIS COMMIT IS FROM, decided before the commit rather than by git's
  # guesser. A CI runner has no `user.name`/`user.email`, and `git commit`
  # there does not just fail -- it fails as one of
  #
  #     *** Please tell me who you are.
  #     fatal: unable to auto-detect email address
  #     fatal: empty ident name (for <>) not allowed
  #
  # each of which arrives at the operator as "publishing scoop to <url>
  # failed", i.e. the wrong cause. The first real `git:` publish would have been diagnosed as
  # a broken remote, a credentials problem, or a missing repository -- anything
  # but the one-line configuration it actually is.
  #
  # A configured identity is preferred when there is one, so a human publishing
  # by hand is attributed to themselves. Otherwise the commit is attributed,
  # visibly and on purpose, to the release automation -- which is what made it.
  # An unattributed or misattributed commit in a published tap is worse than a
  # loud one that names the bot.
  _cname="$( (cd "$_work" && git config --get user.name) 2>/dev/null || true)"
  _cemail="$( (cd "$_work" && git config --get user.email) 2>/dev/null || true)"
  if [ -z "$_cname" ] || [ -z "$_cemail" ]; then
    _cname="${REPRO_PUBLISH_GIT_NAME:-reprobuild release automation}"
    _cemail="${REPRO_PUBLISH_GIT_EMAIL:-releases@reprobuild.com}"
    log "$_surface: no git identity is configured on this host; committing as $_cname <$_cemail> (set \$REPRO_PUBLISH_GIT_NAME / \$REPRO_PUBLISH_GIT_EMAIL to change it)"
  fi

  ( cd "$_work" \
      && git add -A \
      && if git diff --cached --quiet; then
           echo "repro-publish-repos: $_surface is already up to date; nothing to push" >&2
         else
           GIT_AUTHOR_NAME="$_cname" GIT_AUTHOR_EMAIL="$_cemail" \
           GIT_COMMITTER_NAME="$_cname" GIT_COMMITTER_EMAIL="$_cemail" \
           git -c commit.gpgsign=false commit -q -m "reprobuild $version" \
             && git push -q origin HEAD
         fi ) || die "publishing $_surface to $_url failed"
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
  _url="$(downloads_asset_url "$_zipname")"

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
# downloads (the release archives)
# ---------------------------------------------------------------------
#
# THE SURFACE THAT HAD A BUCKET AND NO PREFIX.
#
# `scripts/install/repro-install.sh --method tarball` -- the repo-less
# fallback, and the only install path on a distribution none of apt/dnf/pacman
# covers -- fetches, for asset `A` at version `V`:
#
#   $REPRO_DOWNLOADS_URL/vV/A
#   $REPRO_DOWNLOADS_URL/vV/SHA256SUMS
#   $REPRO_DOWNLOADS_URL/vV/SHA256SUMS.asc
#   $REPRO_DOWNLOADS_URL/vV/A.asc
#
# and $REPRO_DOWNLOADS_URL defaults to https://downloads.reprobuild.com, which
# `infra` provisions as an R2 custom domain over `reprobuild-downloads-prod`.
#
# Nothing ever wrote that bucket. The archives went to the GitHub release and
# stopped there, so on the first real release the bucket would have been empty
# and every tarball install would have 404'd against a hostname that resolves,
# serves, and holds nothing -- the failure that looks least like a
# configuration mistake and most like a broken product.
#
# `--archives <dir>` is release.yml's `staging/`: the exact bytes that were
# published, not a rebuild of them. Absent, this surface is SKIPPED with a
# line saying so, because the M3 gate and today's release step do not pass it
# and a hard failure there would block the trust anchor on an unrelated flag.
publish_downloads() {
  if [ -z "$archives" ]; then
    log 'downloads: no --archives given; not publishing release archives.'
    log 'downloads:   repro-install.sh --method tarball fetches these from'
    log 'downloads:   $REPRO_DOWNLOADS_URL/v<version>/ -- pass --archives <dir>'
    log 'downloads:   (release.yml: staging/) or that path serves nothing.'
    surface_noop 'no --archives given; release archives not published'
    return 0
  fi
  [ -d "$archives" ] || die "--archives $archives is not a directory"
  _abs="$(CDPATH='' cd -- "$archives" && pwd)"
  _root="$repo_root/downloads"
  mkdir -p "$_root/v$version"
  # NO --fetch-existing HERE, deliberately.
  #
  # The other object-store surfaces are stateful: `deb` regenerates one index
  # over a pool that must still contain every older .deb, so the pool has to be
  # pulled down first or publishing 0.1.4 deletes 0.1.3. `downloads` is not
  # like that. Every key it writes is under `v<version>/`, no key outside this
  # version's directory is read or rewritten, and neither uploader passes a
  # delete flag (`aws s3 sync` without `--delete`, `rclone copy` rather than
  # `sync`), so a previous release is untouched whether or not it was fetched.
  #
  # Fetching would therefore download every archive of every past release --
  # the largest objects this pipeline publishes, growing without bound with
  # each release -- to write none of them back. That is release-time minutes
  # and egress spent for no behavioural difference at all.
  if [ "$fetch_existing" -eq 1 ]; then
    log 'downloads: --fetch-existing ignored; every key is under v<version>/ and'
    log 'downloads:   no past release is read, rewritten or deleted by this publish.'
  fi

  _n=0
  for _f in "$_abs"/*; do
    [ -f "$_f" ] || continue
    cp "$_f" "$_root/v$version/"
    _n=$((_n + 1))
  done
  [ "$_n" -gt 0 ] || die "no files in $archives; nothing to publish to downloads"

  # THE FOUR NAMES THE INSTALLER FETCHES, AND ALL FOUR ARE FAIL-CLOSED.
  #
  # `scripts/install/repro-install.sh` (install_tarball, lines 653-660) issues
  # exactly four fetches, and its `fetch` helper `die`s on a non-2xx and again
  # on an empty body -- there is no partial-success path:
  #
  #   $REPRO_DOWNLOADS_URL/v<version>/<asset>
  #   $REPRO_DOWNLOADS_URL/v<version>/SHA256SUMS
  #   $REPRO_DOWNLOADS_URL/v<version>/SHA256SUMS.asc
  #   $REPRO_DOWNLOADS_URL/v<version>/<asset>.asc
  #
  # This check used to cover ONE of them while its comment claimed three. All
  # four are covered now, because a publish missing any one of them is not a
  # degraded install, it is a broken one -- and it breaks only in the user's
  # hands, minutes after the pipeline reported green.
  #
  # The severity is graded to what the absence actually costs, and each grade
  # is stated where it is decided:
  #
  #   SHA256SUMS      -- fatal. Nothing else can be checked without it.
  #   <asset>         -- fatal. SHA256SUMS is the list of assets this release
  #                      claims to ship; one it names and the tree does not
  #                      carry is a publish that has already gone wrong.
  #   SHA256SUMS.asc  -- loud warning, not fatal. See below: this surface must
  #   <asset>.asc        not be able to block the trust anchor, which is the
  #                      thing currently gating every signed install path.
  _vdir="$_root/v$version"
  [ -f "$_vdir/SHA256SUMS" ] \
    || die "downloads: $archives has no SHA256SUMS. repro-install.sh --method tarball fetches it by name and fails closed without it."

  # `<asset>`: the manifest is the authoritative list of what this release
  # ships, so it is also the list of names that must be present. A manifest
  # naming an asset the bucket does not hold is a 404 the installer meets after
  # it has already downloaded and trusted the manifest.
  # Field 2 of each manifest line, with coreutils' binary-mode `*` stripped.
  # Whitespace in an asset name would break this -- and would equally break
  # `sha256sum -c`, which release.yml runs over the same file when it builds
  # it, so the format already forbids what this parse assumes.
  _assets="$(awk '{ n = $2; sub(/^\*/, "", n); if (n != "") print n }' "$_vdir/SHA256SUMS")"
  _absent=''
  for _a in $_assets; do
    [ -f "$_vdir/$_a" ] || _absent="$_absent $_a"
  done
  [ -z "$_absent" ] \
    || die "downloads: SHA256SUMS names asset(s) that are not being published:$_absent.
repro-install.sh --method tarball fetches \$REPRO_DOWNLOADS_URL/v$version/<asset>
by the name the manifest gives, and fails closed on a 404. Publishing the
manifest without the assets it names is a broken install, not a partial one."

  # `SHA256SUMS.asc` and `<asset>.asc`: warned, not fatal, and the warning says
  # what actually happens rather than promising a fallback.
  #
  # There is NO same-origin fallback. The installer's tarball path fetches both
  # signatures unconditionally and `die`s if either is missing, and it locates
  # and runs M2's verifier before unpacking with no rescue branch. So the
  # honest statement is that tarball installs of this version FAIL -- not that
  # they degrade to a weaker check.
  #
  # It stays a warning rather than a `die` because of what a `die` here would
  # cost. `publish_keys` runs AFTER every surface in this script, and it is
  # what publishes the trust anchor -- so dying in this function suppresses
  # the keyring as well as the archives. And an unsigned release is a shape
  # this pipeline supports and has shipped: release.yml's `Sign SHA256SUMS and
  # artifacts` step (which runs BEFORE this one, not after) exits 0 with a
  # `::warning::` when no `REPRO_RELEASE_SIGNING_KEY` secret is configured, and
  # that is exactly the releases so far. Making a missing signature fatal here
  # would mean those releases published no trust anchor at all -- withholding
  # the one artifact a later signed release needs clients to already have.
  # Hence: as loud as a warning can be, and not a `die`.
  #
  # The `<asset>` check above IS fatal, and does block the trust anchor. The
  # line between them is whether the tree is self-contradictory: a manifest
  # naming an asset that is not there is a publish that has already gone
  # wrong, in the same class as a missing SHA256SUMS (fatal here long before
  # this change). A missing signature is a property of the release, not a
  # defect in what is being written.
  if [ -f "$_vdir/SHA256SUMS.asc" ]; then
    log "downloads: SHA256SUMS.asc present (signature-verified installs work)"
  else
    log "downloads: WARNING: no SHA256SUMS.asc at v$version."
    log 'downloads:   repro-install.sh --method tarball fetches it by name and'
    log 'downloads:   fails closed on a 404, and it verifies before unpacking'
    log 'downloads:   with no rescue branch. There is NO same-origin fallback:'
    log 'downloads:   every tarball install of this version will FAIL, not'
    log 'downloads:   degrade. See docs/release-signing.md.'
  fi
  _unsigned=''
  for _a in $_assets; do
    [ -f "$_vdir/$_a.asc" ] || _unsigned="$_unsigned $_a"
  done
  if [ -n "$_unsigned" ]; then
    log "downloads: WARNING: no detached signature for:$_unsigned"
    log 'downloads:   repro-install.sh --method tarball fetches <asset>.asc by'
    log 'downloads:   name and fails closed on a 404, so installs of those'
    log 'downloads:   assets will FAIL. The per-asset signature is not'
    log 'downloads:   redundant with the manifest signature: it is what lets a'
    log 'downloads:   consumer that fetched ONE asset verify it.'
  fi
  log "downloads: staged $_n file(s) at v$version"

  upload_tree "$_root" downloads
}

# ---------------------------------------------------------------------
# homebrew (macOS) -- a TAP, which is a git repository
# ---------------------------------------------------------------------
#
# Same shape as scoop and for the same reason: `brew tap` clones. The formula
# carries the archive URL and its sha256, and brew verifies the digest on
# install, so -- exactly as with Scoop -- the artefact is not signed and no
# signing key is asked for.
#
# `metacraft-labs/homebrew-reprobuild` does not exist. See
# `announce_git_surface_prerequisite`.
publish_homebrew() {
  _root="$repo_root/homebrew"
  mkdir -p "$_root/Formula"
  [ "$fetch_existing" -eq 0 ] || fetch_existing_tree "$_root" homebrew

  _tarball=''
  for _t in "$packages"/*darwin*.tar.gz "$packages"/*macos*.tar.gz; do
    [ -f "$_t" ] || continue
    _tarball="$_t"
    break
  done
  if [ -z "$_tarball" ]; then
    # Under --ecosystem all this is a skip, not a failure: a release without a
    # macOS archive is a real and supported shape (v0.1.2 and v0.1.3 both were
    # one), and dying here would take the trust anchor with it. Asked for
    # EXPLICITLY, it is a failure, because a run that was told to publish a
    # formula and silently published none is the worse answer.
    if [ "$ecosystem" = homebrew ]; then
      die "no *darwin*.tar.gz or *macos*.tar.gz in $packages; cannot write a Homebrew formula"
    fi
    log "homebrew: no macOS archive in $packages; skipping the tap"
    # THE SKIP MUST NOT TAKE THE ANNOUNCEMENT WITH IT.
    #
    # `upload_tree` is the only caller of `announce_git_surface_prerequisite`,
    # and this branch returns before it. It fires on exactly the releases
    # shipped so far -- v0.1.2 and v0.1.3 both carried no macOS archive -- so
    # homebrew emitted no `PREREQUISITE:` block, no marker line and therefore
    # no `::warning::` on every release that has ever run. A graceful
    # degradation that degrades into silence is the failure this script exists
    # to remove, not an instance of handling it.
    announce_surface_skipped homebrew \
      "this release carries no macOS archive (no *darwin*.tar.gz or *macos*.tar.gz in $packages), so no formula was generated and the tap was not updated"
    # And the missing tap is a SEPARATE, still-true fact with a different
    # remedy and a different owner. Say it too: the release that finally does
    # carry a macOS archive can only publish if somebody created the repository
    # in the meantime, and that lead time is exactly what the announcement buys.
    parse_target_spec "$(resolve_surface_target homebrew)"
    if [ "$ts_scheme" = none ]; then
      announce_git_surface_prerequisite homebrew "$_root"
    fi
    surface_noop 'no macOS archive in this release; no formula generated'
    return 0
  fi
  _name="$(basename "$_tarball")"
  _hash="$(sha256sum "$_tarball" | awk '{print $1}')"
  _url="$(downloads_asset_url "$_name")"

  cat > "$_root/Formula/reprobuild.rb" <<FORMULA
class Reprobuild < Formula
  desc "Reproducible build system"
  homepage "https://$scoop_homepage_domain"
  url "$_url"
  sha256 "$_hash"
  version "$version"
  license "Apache-2.0"

  def install
    bin.install Dir["bin/*"]
    lib.install Dir["lib/*"] if Dir.exist?("lib")
  end

  test do
    system "#{bin}/repro", "--version"
  end
end
FORMULA

  # Same assertion as the Scoop manifest, for the same reason: a formula whose
  # digest is not a real digest installs nothing, and only after a user tried.
  _n="$(grep -c 'sha256 "[0-9a-f]\{64\}"' "$_root/Formula/reprobuild.rb" || true)"
  [ "${_n:-0}" -eq 1 ] \
    || die "the generated Homebrew formula does not carry exactly one sha256 (found ${_n:-0})"
  log "homebrew formula: version=$version hash=$_hash"
  log "homebrew formula url: $_url"

  upload_tree "$_root" homebrew
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

# The tally counts what MOVED BYTES, not what was attempted.
#
# `published N ecosystem(s)` used to increment once per selected surface, so a
# git-backed surface with no repository and a homebrew skip both read as
# published. On every release so far that made the last line of the publish
# step overstate the result by two channels -- and the last line is the one an
# operator reads.
#
# `selected` keeps the "nothing to publish" guard honest: a run that publishes
# nothing is not an error if it legitimately no-op'd everything it selected
# (`--ecosystem downloads` with no `--archives` is a supported shape and exits
# 0 today). The error is selecting no surface at all.
selected=0
published=0
noops=''

for _e in deb rpm arch scoop homebrew downloads; do
  want "$_e" || continue
  selected=$((selected + 1))
  surface_result='published'
  surface_result_reason=''
  case "$_e" in
    deb)       publish_deb ;;
    rpm)       publish_rpm ;;
    arch)      publish_arch ;;
    scoop)     publish_scoop ;;
    homebrew)  publish_homebrew ;;
    downloads) publish_downloads ;;
  esac
  if [ "$surface_result" = published ]; then
    published=$((published + 1))
  else
    noops="$noops
  $_e: $surface_result_reason"
  fi
done
[ "$selected" -gt 0 ] || die "--ecosystem $ecosystem selected nothing to publish"
publish_keys

log "published $published of $selected selected ecosystem(s) for version $version"
# The no-ops stay VISIBLE. Dropping them from the tally without printing them
# would trade one wrong number for a smaller true one and lose the reason.
if [ -n "$noops" ]; then
  log "$((selected - published)) selected ecosystem(s) published nothing:$noops"
fi
log "repo root: $repo_root ($(count_files "$repo_root") files)"
