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
# This script prints the prerequisite on every run that stages one of them.
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
    -h|--help)    sed -n '2,110p' "$0"; exit 0 ;;
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
      else
        log "$_sub: target=none; generated under $_src, uploaded nothing"
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
# when no remote is named it says -- on every single run, in the release log,
# not in a terraform output nobody will run -- exactly which repository has to
# exist and exactly what to pass once it does.
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
  ( cd "$_work" \
      && git add -A \
      && if git diff --cached --quiet; then
           echo "repro-publish-repos: $_surface is already up to date; nothing to push" >&2
         else
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
    return 0
  fi
  [ -d "$archives" ] || die "--archives $archives is not a directory"
  _abs="$(CDPATH='' cd -- "$archives" && pwd)"
  _root="$repo_root/downloads"
  mkdir -p "$_root/v$version"
  [ "$fetch_existing" -eq 0 ] || fetch_existing_tree "$_root" downloads

  _n=0
  for _f in "$_abs"/*; do
    [ -f "$_f" ] || continue
    cp "$_f" "$_root/v$version/"
    _n=$((_n + 1))
  done
  [ "$_n" -gt 0 ] || die "no files in $archives; nothing to publish to downloads"

  # The three names the installer asks for BY NAME. A publish that copied
  # archives but no manifest would leave `--method tarball` fetching a
  # SHA256SUMS that 404s, and the installer treats that as a hard failure --
  # correctly, but only after the user tried.
  for _need in SHA256SUMS; do
    [ -f "$_root/v$version/$_need" ] \
      || die "downloads: $archives has no $_need. repro-install.sh --method tarball fetches it by name and fails closed without it."
  done
  if [ -f "$_root/v$version/SHA256SUMS.asc" ]; then
    log "downloads: SHA256SUMS.asc present (signature-verified installs work)"
  else
    log "downloads: WARNING: no SHA256SUMS.asc. Installs fall back to same-origin integrity only; see docs/release-signing.md."
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
    return 0
  fi
  _name="$(basename "$_tarball")"
  _hash="$(sha256sum "$_tarball" | awk '{print $1}')"
  _url="${REPRO_DOWNLOADS_BASE:-$scoop_downloads_base}/v$version/$_name"

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

published=0
if want deb;       then publish_deb;       published=$((published + 1)); fi
if want rpm;       then publish_rpm;       published=$((published + 1)); fi
if want arch;      then publish_arch;      published=$((published + 1)); fi
if want scoop;     then publish_scoop;     published=$((published + 1)); fi
if want homebrew;  then publish_homebrew;  published=$((published + 1)); fi
if want downloads; then publish_downloads; published=$((published + 1)); fi
[ "$published" -gt 0 ] || die "--ecosystem $ecosystem selected nothing to publish"
publish_keys

log "published $published ecosystem(s) for version $version"
log "repo root: $repo_root ($(count_files "$repo_root") files)"
