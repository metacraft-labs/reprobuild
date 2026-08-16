#!/usr/bin/env bash
# install-release.sh — install the prebuilt `repro` CLI from a GitHub Release.
#
# This is the fast path of the `setup-reprobuild` action: shipping prebuilt
# portable binaries is the whole point of publishing release archives, and
# before this script existed the action ignored them entirely and rebuilt the
# CLI from source on every consumer, on every run.
#
# Contract (deliberately narrow so the caller can branch on it):
#
#   exit 0  — installed. The absolute path of the directory holding `repro`
#             is written to stdout on the last line, prefixed `REPRO_BIN_DIR=`.
#   exit 3  — this platform/release cannot be served from a release archive
#             (no asset for the platform, or no publishable checksum to verify
#             it against). The caller MUST fall back to the source build, and
#             MUST announce it. A diagnostic explaining which of the two it was
#             is written to stderr.
#   exit 1  — a real error (download broke, checksum MISMATCHED, archive
#             corrupt). Never fall back on this: a mismatching checksum is a
#             security event, not a missing feature.
#
# The 3-vs-1 split matters. "No Windows asset in this release" is a routine,
# expected state that source-build covers. "The Windows asset does not match
# the checksum the release publishes" is not, and silently source-building past
# it would hide exactly the thing the verification exists to catch.
#
# That split is only sound if 3 is UNREACHABLE by accident, which it was not
# when this script was first written. Exit 3 was reachable from any tool that
# happened to exit 3 under `set -e` -- and `unzip` exits 3 on "a severe error in
# the zipfile format", i.e. exactly a corrupt Windows archive. A corrupt zip
# therefore reported "no asset for this platform" and silently source-built,
# which is the precise outcome the paragraph above forbids. So: exit 3 is now
# raised ONLY by skip(), and an ERR trap converts every other unexpected
# non-zero status into exit 1. Never `exit 3` from anywhere but skip().
#
# Dependencies are deliberately minimal — curl, tar/unzip, and a SHA-256 tool —
# because this runs on GARM-provisioned Windows and macOS images that cannot be
# assumed to carry jq, python3, or the `gh` CLI. Nothing here parses JSON beyond
# a single scalar (`tag_name`), and asset *existence* is determined by the HTTP
# status of the download rather than by parsing the asset array.

# -E so the ERR trap below is inherited by functions and subshells; without it
# a failure inside a function would bypass the trap and leak its own status.
set -Eeuo pipefail

REPO="${REPRO_REPO:-metacraft-labs/reprobuild}"
VERSION="${REPRO_VERSION:-latest}"
INSTALL_DIR="${REPRO_INSTALL_DIR:?REPRO_INSTALL_DIR must be set}"
CHECKSUM_FILE_NAME="SHA256SUMS"

# Verification is opt-OUT, and the opt-out must be spelled exactly. Anything
# that is not the literal string `false` means "verify" -- including `True`,
# `1`, `yes` and typos. This used to be inverted (`= "true"` enabled it), so
# `require-checksum: True` silently installed an archive with no integrity
# check at all: a security control that fails OPEN on a typo is not a control.
case "${REPRO_REQUIRE_CHECKSUM:-true}" in
  false|False|FALSE) REQUIRE_CHECKSUM=false ;;
  *)                 REQUIRE_CHECKSUM=true ;;
esac

# Origin overrides. Default to github.com / api.github.com; they exist so this
# script can be pointed at an internal mirror, and so its download + verify +
# unpack path can be exercised end-to-end in a test against a local server
# instead of being reachable only by cutting a real release. Same pattern as
# RUSTUP_DIST_SERVER / NVM_NODEJS_ORG_MIRROR. Anyone able to set these already
# controls the job environment, so they widen no meaningful attack surface —
# but point them only at an origin you trust.
DOWNLOAD_ORIGIN="${REPRO_RELEASE_DOWNLOAD_ORIGIN:-https://github.com}"
API_ORIGIN="${REPRO_RELEASE_API_ORIGIN:-https://api.github.com}"

log()  { printf '%s\n' "setup-reprobuild: $*" >&2; }
die()  { printf '%s\n' "setup-reprobuild: ERROR: $*" >&2; exit 1; }
# Exit 3 == "not servable from a release"; the caller turns this into an
# announced source-build fallback. SKIPPING is the ONLY producer of 3.
SKIPPING=0
skip() { printf '%s\n' "setup-reprobuild: $*" >&2; SKIPPING=1; exit 3; }

# Any command that dies under `set -e` would otherwise propagate its own exit
# status, and several of the tools used below exit 3 on corruption (unzip does
# so for "a severe error in the zipfile format"). Exit 3 is the caller's signal
# to source-build SILENTLY, so an unguarded tool failure could downgrade a
# corrupt archive into an unannounced fallback. Collapse every unexpected
# status to 1; only a deliberate skip() keeps 3.
on_err() {
  local rc=$?
  [ "${SKIPPING}" = "1" ] && exit "${rc}"
  printf '%s\n' "setup-reprobuild: ERROR: unexpected failure (status ${rc}) at line ${BASH_LINENO[0]:-?}; treating as a hard error, NOT as 'no prebuilt available'." >&2
  exit 1
}
trap on_err ERR

# ── Platform identity ────────────────────────────────────────────────────────
#
# These strings must match the `platform`/`arch` fields the release workflow
# uses to name its archives (.github/release-platforms.json). Keep them in sync;
# a mismatch here degrades silently into "no asset for this platform" and every
# consumer quietly source-builds forever.
detect_platform() {
  local uname_s uname_m
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"

  case "${uname_s}" in
    Linux)                        PLATFORM=linux;   ARCHIVE_EXT=tar.gz ;;
    Darwin)                       PLATFORM=darwin;  ARCHIVE_EXT=tar.gz ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) PLATFORM=windows; ARCHIVE_EXT=zip ;;
    *) skip "unrecognised OS '${uname_s}'; no release archive can be selected" ;;
  esac

  case "${uname_m}" in
    x86_64|amd64)   ARCH=x86_64 ;;
    arm64|aarch64)  ARCH=aarch64 ;;
    *) skip "unrecognised CPU '${uname_m}'; no release archive can be selected" ;;
  esac
}

# ── SHA-256, portably ────────────────────────────────────────────────────────
# coreutils `sha256sum` on Linux and Git-for-Windows; BSD `shasum` on macOS.
sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    die "no sha256sum or shasum on PATH; cannot verify the release archive"
  fi
}

# Download ${2} to ${1}. Echoes the HTTP status; never fails the script itself
# so the caller can distinguish 404 (routine) from 500 (an error).
#
# `--location` is required (release asset URLs redirect to object storage), and
# following redirects is exactly why the protocol has to be pinned: without
# --proto-redir a redirect may downgrade an https download to plaintext http,
# and TLS is the ONLY thing standing between this script and a swapped binary
# when SHA256SUMS comes from the same origin. Pinned only when the configured
# origin is already https, so the local-server test path still works.
http_get() {
  local dest="$1" url="$2" code
  local -a proto=()
  case "${url}" in
    https://*) proto=(--proto '=https' --proto-redir '=https') ;;
  esac
  local -a auth=()
  # Authenticate the API call when a token is available. Unauthenticated
  # api.github.com is 60 requests/hour PER IP, and the whole ephemeral runner
  # fleet shares one egress IP -- so without this, `repro-version: latest`
  # resolution starts returning 403 under normal load, which this script reads
  # as "cannot resolve latest" and turns into a silent, slow source build.
  if [ -n "${REPRO_GITHUB_TOKEN:-}" ]; then
    case "${url}" in
      "${API_ORIGIN}"/*) auth=(--header "Authorization: Bearer ${REPRO_GITHUB_TOKEN}") ;;
    esac
  fi
  code="$(curl --silent --show-error --location \
                "${proto[@]+"${proto[@]}"}" "${auth[@]+"${auth[@]}"}" \
                --retry 3 --retry-delay 2 --retry-connrefused \
                --write-out '%{http_code}' \
                --output "${dest}" "${url}" || true)"
  printf '%s' "${code}"
}

resolve_tag() {
  # An explicit pin is used verbatim (accepting both `v0.1.3` and `0.1.3`).
  if [ -n "${VERSION}" ] && [ "${VERSION}" != "latest" ]; then
    # ── Validate before it reaches a URL or a filesystem path ────────────────
    #
    # This value is interpolated into BOTH the download URL and a local file
    # name, so it is not a cosmetic check. Unvalidated, `repro-version` was a
    # path-traversal primitive: curl strips `/../` segments from a URL path
    # before sending it (that is default behaviour -- `--path-as-is` disables
    # it), so a value like
    #     0.1.3/../../../../attacker/evil/releases/download/v1
    # made the SHA256SUMS request resolve to an ATTACKER-CHOSEN path on the
    # download origin. Verified: the request observed on the wire was
    #     GET /attacker/evil/releases/download/v9.9.9/SHA256SUMS
    # instead of /metacraft-labs/reprobuild/... . Since github.com serves every
    # user's release assets, that is "download and execute a binary from a repo
    # of the attacker's choosing", with the same-origin SHA256SUMS obligingly
    # coming from the attacker's path too, so verification passes.
    #
    # A tag is a version, not a path. Allow only what a tag can be.
    case "${VERSION}" in
      *[!A-Za-z0-9.+_-]*)
        die "invalid repro-version '${VERSION}': only letters, digits and . + _ - are allowed.
        A version is a release tag (e.g. 0.2.0, v0.2.0, 0.2.0-rc1), not a path or an expression." ;;
    esac
    case "${VERSION}" in
      *..*) die "invalid repro-version '${VERSION}': '..' is not permitted in a tag." ;;
    esac
    case "${VERSION}" in
      v*) TAG="${VERSION}" ;;
      *)  TAG="v${VERSION}" ;;
    esac
    return
  fi

  # `latest` needs one API call. Only a single top-level scalar is read, so no
  # JSON parser is required.
  local tmp code
  tmp="$(mktemp)"
  code="$(http_get "${tmp}" "${API_ORIGIN}/repos/${REPO}/releases/latest")"
  if [ "${code}" != "200" ]; then
    rm -f "${tmp}"
    skip "could not resolve the latest release of ${REPO} (HTTP ${code})"
  fi
  TAG="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${tmp}" | head -n 1)"
  rm -f "${tmp}"
  [ -n "${TAG}" ] || skip "the latest release of ${REPO} has no tag_name"

  # The tag from the API lands in a URL and a filename exactly as a pinned one
  # does, so it gets the same treatment. A response body is attacker-shaped
  # input the moment the API origin is not the one you think it is.
  case "${TAG}" in
    *[!A-Za-z0-9.+_-]*|*..*)
      die "refusing tag_name '${TAG}' from ${API_ORIGIN}: not a plausible release tag." ;;
  esac
}

main() {
  detect_platform
  resolve_tag

  # Archive names embed the *nimble* version, which is the tag without its
  # leading `v` (release.yml derives both from reprobuild.nimble).
  local version asset_name base_url
  version="${TAG#v}"
  asset_name="reprobuild-${version}-${PLATFORM}-${ARCH}.${ARCHIVE_EXT}"
  base_url="${DOWNLOAD_ORIGIN}/${REPO}/releases/download/${TAG}"

  log "resolved release ${TAG}; want ${asset_name}"

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $work now, not at trap time
  trap "rm -rf '${work}'" EXIT

  # ── Fetch the checksum manifest FIRST ──────────────────────────────────────
  #
  # Fetching it before the archive means an unverifiable release costs one small
  # request instead of a ~16 MB download we would then have to throw away.
  #
  # Honesty about what this buys: SHA256SUMS is served from the same origin as
  # the archive, so it is an integrity check against truncation, a corrupted
  # mirror, or a partially-uploaded asset — NOT a trust root against an attacker
  # who controls the release. It satisfies "verified against something the
  # release publishes"; upgrading to a real trust root means signing (cosign /
  # GitHub artifact attestations) and is a separate change.
  local sums_path sums_code
  sums_path="${work}/${CHECKSUM_FILE_NAME}"
  sums_code="$(http_get "${sums_path}" "${base_url}/${CHECKSUM_FILE_NAME}")"

  if [ "${sums_code}" = "404" ]; then
    if [ "${REQUIRE_CHECKSUM}" = "true" ]; then
      # Releases v0.1.0 .. v0.1.3 predate checksum publication, so this is the
      # expected outcome for them. Refusing to install unverified is the safe
      # default; `require-checksum: false` is the documented opt-out.
      skip "release ${TAG} publishes no ${CHECKSUM_FILE_NAME}, so its archives cannot be verified. \
Set require-checksum: false to install anyway (NOT recommended), or use a release cut by the \
current release workflow."
    fi
    log "WARNING: release ${TAG} publishes no ${CHECKSUM_FILE_NAME} and require-checksum is false; \
installing WITHOUT integrity verification."
    sums_path=""
  elif [ "${sums_code}" != "200" ]; then
    die "fetching ${CHECKSUM_FILE_NAME} from ${TAG} failed with HTTP ${sums_code}"
  fi

  # ── Fetch the archive ──────────────────────────────────────────────────────
  local archive_path archive_code
  archive_path="${work}/${asset_name}"
  archive_code="$(http_get "${archive_path}" "${base_url}/${asset_name}")"

  if [ "${archive_code}" = "404" ]; then
    skip "release ${TAG} has no asset ${asset_name} (no prebuilt binary for ${PLATFORM}-${ARCH})"
  elif [ "${archive_code}" != "200" ]; then
    die "downloading ${asset_name} failed with HTTP ${archive_code}"
  fi

  # ── Verify ─────────────────────────────────────────────────────────────────
  if [ -n "${sums_path}" ]; then
    local expected actual
    # Match the exact asset name in column 2; `*name` and `name` forms both
    # appear depending on whether the producer used binary mode.
    expected="$(awk -v want="${asset_name}" \
      '{ n=$2; sub(/^\*/,"",n); if (n==want) { print $1; exit } }' "${sums_path}")"
    if [ -z "${expected}" ]; then
      # The manifest exists but omits our archive. That means the release is
      # internally inconsistent — publish gating should make it impossible —
      # so treat it as an error rather than installing something unattested.
      die "${CHECKSUM_FILE_NAME} of ${TAG} contains no entry for ${asset_name}; refusing to install unverified"
    fi
    actual="$(sha256_of "${archive_path}")"
    if [ "${actual}" != "${expected}" ]; then
      die "checksum MISMATCH for ${asset_name}
        expected ${expected}
        actual   ${actual}
        Refusing to install. Do NOT fall back to a source build for this — investigate the release."
    fi
    log "sha256 verified against ${CHECKSUM_FILE_NAME}: ${actual}"
  fi

  # ── Unpack ─────────────────────────────────────────────────────────────────
  #
  # Archives contain exactly one top-level directory `reprobuild-<v>-<p>-<a>/`
  # with sibling `bin/` and `lib/`. That adjacency is load-bearing: the CLI
  # dlopens its shim/runtime libraries relative to itself, so the tree is copied
  # wholesale rather than having `bin/*` scraped out of it.
  # Every unpack failure is routed through die() (exit 1). It must NOT be
  # allowed to surface the extractor's own status: `unzip` exits 3 on a corrupt
  # zip and 3 is the caller's "no prebuilt here, source-build quietly" signal,
  # so a corrupt Windows archive used to vanish into an unannounced fallback.
  local extract_dir pkg_dir
  extract_dir="${work}/x"
  mkdir -p "${extract_dir}"
  case "${ARCHIVE_EXT}" in
    tar.gz)
      tar -xzf "${archive_path}" -C "${extract_dir}" \
        || die "archive ${asset_name} could not be extracted (corrupt or truncated tar.gz)"
      ;;
    zip)
      if command -v unzip >/dev/null 2>&1; then
        # -o so a zip carrying duplicate entry names cannot block on unzip's
        # interactive "replace?" prompt; </dev/null for the same reason.
        unzip -q -o "${archive_path}" -d "${extract_dir}" </dev/null \
          || die "archive ${asset_name} could not be extracted (corrupt or truncated zip)"
      else
        # Windows images reliably carry bsdtar as tar.exe even without unzip.
        tar -xf "${archive_path}" -C "${extract_dir}" \
          || die "archive ${asset_name} could not be extracted (corrupt or truncated zip)"
      fi
      ;;
  esac

  # Select the package directory BY NAME rather than taking whatever `find`
  # happens to return first. An archive may legitimately unpack to more than
  # one top-level entry -- unzip, for instance, sanitises a `../../tmp/x` entry
  # into a local `tmp/` directory rather than rejecting it (verified) -- and
  # "first directory in filesystem order, must contain bin/" would then be
  # satisfiable by a directory the archive author chose.
  pkg_dir="${extract_dir}/reprobuild-${version}-${PLATFORM}-${ARCH}"
  if [ ! -d "${pkg_dir}" ]; then
    die "archive ${asset_name} does not contain the expected top-level directory \
reprobuild-${version}-${PLATFORM}-${ARCH}/ (found: $(find "${extract_dir}" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | tr '\n' ' '))"
  fi
  [ -d "${pkg_dir}/bin" ] || die "archive ${asset_name} has no bin/ directory"

  # Refuse a tree containing a symlink that points outside itself. GNU tar and
  # unzip both already block `..`/absolute-path MEMBERS (verified: the escape
  # attempts land inside the extract dir or are rejected outright), but neither
  # stops a plain symlink whose TARGET is absolute -- an archive shipping
  # `bin/repro -> /some/host/binary` would otherwise be installed and executed.
  local bad_link
  bad_link="$(find "${pkg_dir}" -type l -print 2>/dev/null | while IFS= read -r l; do
      target="$(readlink "${l}")"
      case "${target}" in
        /*|*..*) printf '%s -> %s\n' "${l}" "${target}" ;;
      esac
    done | head -n 5 || true)"
  if [ -n "${bad_link}" ]; then
    die "archive ${asset_name} contains symlink(s) pointing outside the package; refusing to install:
${bad_link}"
  fi

  rm -rf "${INSTALL_DIR}"
  mkdir -p "$(dirname "${INSTALL_DIR}")"
  mv "${pkg_dir}" "${INSTALL_DIR}"

  local repro_bin="${INSTALL_DIR}/bin/repro"
  [ "${PLATFORM}" = "windows" ] && repro_bin="${repro_bin}.exe"
  [ -f "${repro_bin}" ] || die "installed tree has no ${repro_bin}"
  chmod +x "${INSTALL_DIR}/bin/"* 2>/dev/null || true

  # Prove the thing actually runs before declaring success. A downloaded archive
  # that cannot exec (missing loader, wrong arch, absent runtime library) should
  # fail here, loudly, rather than three steps later inside somebody's build.
  if ! "${repro_bin}" --version >/dev/null 2>&1; then
    die "installed ${repro_bin} does not execute (missing runtime dependency, or wrong architecture)"
  fi
  log "installed $("${repro_bin}" --version 2>&1 | head -n 1) from release ${TAG}"

  printf 'REPRO_BIN_DIR=%s\n' "${INSTALL_DIR}/bin"
}

main "$@"
