#!/bin/sh
# Turn a release tarball into NATIVE packages: .deb, .rpm, .pkg.tar.zst, and
# (on macOS, with pkgbuild) a component .pkg.
#
#   repro-build-packages.sh --version 0.1.3 --tarball <path> \
#       --out <dir> [--ecosystem deb|rpm|arch|pkg|all] [--arch amd64]
#
# `all` is deb, rpm and arch. The macOS `.pkg` is built only when asked for
# (`--ecosystem pkg --platform darwin`), because it needs pkgbuild, which
# exists on macOS only; no release asset is declared for it
# (.github/release-platforms.json).
#
# The tarball is the release asset release.yml already produces:
#   reprobuild-<version>-<platform>-<arch>.tar.gz
# containing reprobuild-<version>-<platform>-<arch>/{bin,lib,share}/, where
# share/repro/completions/ holds repro's shell completion scripts.
#
# ## Why repackage rather than build per-distro
#
# reprobuild's release build is a nix/devshell build producing one set of
# binaries per platform; it is not a distro source build. So the native
# packages are *carriers* for the same bytes the tarball carries, which
# means (a) the .deb and the tarball are byte-identical in payload and a
# user who switches methods gets the same program, and (b) adding an
# ecosystem is packaging work, not a new build matrix leg. The all-or-
# nothing release contract in .github/release-platforms.json stays the
# single source of truth for what exists.
#
# ## What this deliberately does NOT do
#
# It does not declare dependencies on distro libraries. reprobuild ships
# its runtime libraries in lib/ (that is what release.yml stages), so a
# generated dependency list would either be empty-and-honest or wrong-
# and-fragile. `Depends:` is left minimal on purpose; when reprobuild
# starts linking distro libs, that is the moment to generate them with
# dpkg-shlibdeps rather than to hand-write a list now.

set -eu

BP_SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

version=''; tarball=''; out=''; ecosystem='all'
deb_arch=''; rpm_arch=''; pkg_arch=''
platform='linux'; asset_arch='x86_64'
maintainer="${REPRO_PACKAGE_MAINTAINER:-Metacraft Labs <info@metacraft-labs.com>}"
homepage="${REPRO_PACKAGE_HOMEPAGE:-https://reprobuild.com}"
# Release iteration. Bumping this republishes the same upstream version as
# a strictly newer package, which is what a packaging-only fix needs.
release_num="${REPRO_PACKAGE_RELEASE:-1}"

log()  { printf 'repro-build-packages: %s\n' "$*" >&2; }
die()  { printf 'repro-build-packages: ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   version="$2"; shift 2 ;;
    --tarball)   tarball="$2"; shift 2 ;;
    --out)       out="$2"; shift 2 ;;
    --ecosystem) ecosystem="$2"; shift 2 ;;
    --platform)  platform="$2"; shift 2 ;;
    --asset-arch) asset_arch="$2"; shift 2 ;;
    --release)   release_num="$2"; shift 2 ;;
    -h|--help)   sed -n '2,36p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$version" ] || die '--version is required'
[ -n "$tarball" ] || die '--tarball is required'
[ -f "$tarball" ] || die "--tarball $tarball does not exist"
[ -n "$out" ]     || die '--out is required'
mkdir -p "$out"
out="$(CDPATH='' cd -- "$out" && pwd)"
tarball="$(CDPATH='' cd -- "$(dirname -- "$tarball")" && pwd)/$(basename -- "$tarball")"

# Map the release asset's arch token onto each ecosystem's own spelling.
# These three genuinely differ (amd64 / x86_64 / x86_64) and getting one
# wrong yields a package the manager silently will not consider.
case "$asset_arch" in
  x86_64)  deb_arch='amd64';  rpm_arch='x86_64';  pkg_arch='x86_64' ;;
  aarch64) deb_arch='arm64';  rpm_arch='aarch64'; pkg_arch='aarch64' ;;
  *) die "unsupported --asset-arch $asset_arch" ;;
esac

topdir="reprobuild-$version-$platform-$asset_arch"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT INT TERM

log "unpacking $tarball"
tar -xzf "$tarball" -C "$stage" || die "could not unpack $tarball"
payload="$stage/$topdir"
[ -d "$payload" ] || die "tarball did not contain $topdir/ (found: $(ls "$stage"))"
[ -d "$payload/bin" ] || die "$topdir/bin is missing; refusing to package a release with no binaries"

# Refusing an empty bin/ is not pedantry: an empty payload produces a
# package that installs cleanly and provides nothing, and every
# downstream check ("did apt install it?") still passes. That is the
# exact shape of a false green.
nbin="$(find "$payload/bin" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$nbin" -gt 0 ] || die "$topdir/bin contains no files; refusing to build an empty package"
log "payload: $nbin file(s) in bin/"

# ---------------------------------------------------------------------
# The installed filesystem tree, shared by every ecosystem
# ---------------------------------------------------------------------
# The archive's bin/ holds portable LAUNCHERS that exec the real binary
# through the bundled loader at "$(dirname "$0")/../lib". That relative
# lookup is the archive's whole relocation contract, so the tree is
# installed INTACT under /usr/lib/reprobuild (bin, lib, share, ...). Spreading bin/ into
# /usr/bin and lib/ into /usr/lib/reprobuild -- what the packages did
# before -- points every launcher at /usr/lib/ld-linux-x86-64.so.2 with
# /usr/lib as its library path: the bundled loader is not there, and a
# host library directory is. The package installs and nothing runs.
#
# /usr/bin gets one two-line wrapper per public command. A symlink would
# not do: the launcher resolves its OWN directory from $0, which through
# a symlink is /usr/bin.
#
# The prefix is /usr for the Linux packages and /usr/local for the macOS .pkg:
# macOS's /usr is read-only (system integrity protection), and /usr/local is
# the location installers there write to.
stage_tree() {
  _t="$1"
  _fmt="$2"
  case "$_fmt" in
    pkg) _pfx='usr/local' ;;
    *)   _pfx='usr' ;;
  esac
  mkdir -p "$_t/$_pfx/bin" "$_t/$_pfx/lib/reprobuild"
  # The WHOLE archive tree, not a list of known subdirectories. v0.2.3's
  # archive gained share/repro/{source,src} (the Nim sources an installed
  # repro compiles recipes against, found at <prefix>/share/repro/source
  # from the binary's own location), and a copy of only bin/ and lib/
  # shipped .deb/.rpm packages whose repro failed its first compile. What
  # the archive carries, the package carries.
  cp -a "$payload/." "$_t/$_pfx/lib/reprobuild/"
  # The archive's bin/ carries runquotad, which the engine starts when no
  # RunQuota daemon answers; under --tool-provisioning=tarball and nix a build
  # cannot run without one. It is NOT given a /usr/bin wrapper: runquota's own
  # .deb and .rpm install /usr/bin/runquotad and /usr/bin/runquota, and two
  # packages owning one path cannot both be installed. The wrappers name it in
  # RUNQUOTAD_BIN instead, the first place the engine looks, unless the caller
  # already chose one.
  _runquotad_line=''
  if [ -x "$payload/bin/runquotad" ]; then
    _runquotad_line=": \"\${RUNQUOTAD_BIN:=/$_pfx/lib/reprobuild/bin/runquotad}\"; export RUNQUOTAD_BIN\\n"
  fi
  _ncmd=0
  for _c in "$payload/bin"/*; do
    _n="$(basename "$_c")"
    # Public commands only: not the dot-prefixed `.X.real` binaries the
    # launchers exec, not data files that live beside them, and not
    # runquota's commands (above).
    case "$_n" in .*|*.json|runquotad|runquota) continue ;; esac
    [ -f "$_c" ] && [ -x "$_c" ] || continue
    # shellcheck disable=SC2059 # the format is assembled from fixed text
    printf "#!/bin/sh\n${_runquotad_line}exec /$_pfx/lib/reprobuild/bin/%s \"\$@\"\n" "$_n" > "$_t/$_pfx/bin/$_n"
    chmod 0755 "$_t/$_pfx/bin/$_n"
    _ncmd=$((_ncmd + 1))
  done
  [ "$_ncmd" -gt 0 ] || die "no public commands in $topdir/bin; refusing to build a package that puts nothing on PATH"
  [ -x "$_t/$_pfx/bin/repro" ] || die "$topdir/bin has no 'repro' command"
  stage_completions "$_t" "$_fmt"
}

# ---------------------------------------------------------------------
# Shell completion
# ---------------------------------------------------------------------
# The archive carries repro's completion scripts at share/repro/completions/,
# generated by the release leg's own binary
# (scripts/release/stage_release_completions.sh). The package installs a copy
# of each where that distribution's shells load completion with no setup by
# the user:
#
#   Bash  /usr/share/bash-completion/completions/repro
#         bash-completion loads completions/<command> on first use, from each
#         XDG_DATA_DIRS entry; packagers read the directory from
#         `pkg-config --variable=completionsdir bash-completion`
#         (https://github.com/scop/bash-completion/blob/main/README.md).
#         The name is the unsuffixed `repro`, which every bash-completion
#         release reads.
#   Zsh   /usr/share/zsh/vendor-completions/_repro on Debian and Ubuntu, whose
#         zsh puts other packages' functions there (the zsh package's
#         README.Debian); /usr/share/zsh/site-functions/_repro on Fedora and
#         Arch, whose zsh has it in the default fpath.
#   Fish  /usr/share/fish/vendor_completions.d/repro.fish, the directory fish
#         names for packages (`pkg-config --variable completionsdir fish`;
#         https://fishshell.com/docs/current/completions.html#where-to-put-completions).
#
# The macOS .pkg installs under /usr/local instead (macOS's /usr is read-only):
# the same three files at /usr/local/share/bash-completion/completions/repro,
# /usr/local/share/zsh/site-functions/_repro and
# /usr/local/share/fish/vendor_completions.d/repro.fish. The first two
# directories are on the default search path of bash-completion and of macOS's
# own zsh; see the comment at build_pkg for what was measured.
#
# A missing source file is a hard failure, not a package without that shell:
# a package that installs but leaves one shell without completion passes every
# install check and fails only the user.
stage_completions() {
  _t="$1"
  _fmt="$2"
  _src="$payload/share/repro/completions"
  case "$_fmt" in
    deb)     _share='usr/share'; _zsh_dir='usr/share/zsh/vendor-completions' ;;
    rpm|arch) _share='usr/share'; _zsh_dir='usr/share/zsh/site-functions' ;;
    pkg)     _share='usr/local/share'; _zsh_dir='usr/local/share/zsh/site-functions' ;;
    *) die "stage_tree: unknown package format '$_fmt'" ;;
  esac
  for _pair in \
    "repro.bash:$_share/bash-completion/completions/repro" \
    "_repro:$_zsh_dir/_repro" \
    "repro.fish:$_share/fish/vendor_completions.d/repro.fish" ; do
    _from="$_src/${_pair%%:*}"
    _to="$_t/${_pair#*:}"
    [ -s "$_from" ] || die "$topdir/share/repro/completions/${_pair%%:*} is missing or empty; the release leg stages it with scripts/release/stage_release_completions.sh"
    mkdir -p "$(dirname "$_to")"
    cp "$_from" "$_to"
    chmod 0644 "$_to"
  done
}

want() {
  case "$ecosystem" in
    all) return 0 ;;
    "$1") return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------
# .deb
# ---------------------------------------------------------------------
build_deb() {
  command -v dpkg-deb >/dev/null 2>&1 || die 'dpkg-deb not found (install dpkg-dev)'
  _root="$stage/deb"
  rm -rf "$_root"
  mkdir -p "$_root/DEBIAN"
  stage_tree "$_root" deb

  cat > "$_root/DEBIAN/control" <<CONTROL
Package: reprobuild
Version: $version-$release_num
Section: devel
Priority: optional
Architecture: $deb_arch
Maintainer: $maintainer
Homepage: $homepage
Description: Reproducible build system
 Reprobuild builds software reproducibly from declarative recipes.
 .
 This package carries the same binaries as the
 $topdir.tar.gz release asset.
CONTROL

  dpkg-deb --build --root-owner-group "$_root" \
    "$out/reprobuild_${version}-${release_num}_${deb_arch}.deb" >/dev/null \
    || die 'dpkg-deb --build failed'
  log "built $out/reprobuild_${version}-${release_num}_${deb_arch}.deb"
}

# ---------------------------------------------------------------------
# .rpm
# ---------------------------------------------------------------------
build_rpm() {
  command -v rpmbuild >/dev/null 2>&1 || die 'rpmbuild not found (install rpm-build)'
  _top="$stage/rpmbuild"
  mkdir -p "$_top/SPECS" "$_top/SOURCES" "$_top/BUILD" "$_top/RPMS" "$_top/SRPMS"
  _tree="$stage/rpmtree"
  rm -rf "$_tree"
  stage_tree "$_tree" rpm
  ( cd "$_tree" && tar -cf "$_top/SOURCES/tree.tar" usr ) || die 'could not archive the rpm tree'

  # %define _build_id_links none: rpm 4.14+ generates /usr/lib/.build-id
  # symlinks from ELF notes and FAILS the build on a collision. Our
  # binaries come from a foreign build with whatever build-ids nix gave
  # them; we are not producing debuginfo packages, so the links have no
  # consumer and their only effect is a spurious build failure.
  cat > "$_top/SPECS/reprobuild.spec" <<SPEC
%global __os_install_post %{nil}
%global debug_package %{nil}
%define _build_id_links none

Name:           reprobuild
Version:        $version
Release:        $release_num%{?dist}
Summary:        Reproducible build system
License:        Apache-2.0
URL:            $homepage
Source0:        tree.tar
BuildArch:      $rpm_arch
# The payload is prebuilt binaries from the release tarball, so there is
# nothing to compile here and no BuildRequires.
AutoReqProv:    no

%description
Reprobuild builds software reproducibly from declarative recipes.
This package carries the same binaries as the $topdir.tar.gz
release asset.

%prep

%build
# Nothing to build: this is a repackaging of a released binary tarball.

%install
# Literal paths, not %{_bindir}/%{_libdir}: an rpm built by Nix defines
# those as its OWN store path, so the package would install into
# /nix/store/...-rpm-<ver>/bin. The tree is the one every ecosystem ships.
mkdir -p %{buildroot}
tar -xf %{SOURCE0} -C %{buildroot}

%files
/usr/bin/*
/usr/lib/reprobuild
# The completion FILES, not their directories. The directories belong to the
# bash-completion, zsh and fish packages; listing them here would make this
# package a second owner of directories it did not create.
/usr/share/bash-completion/completions/repro
/usr/share/zsh/site-functions/_repro
/usr/share/fish/vendor_completions.d/repro.fish

%changelog
* Mon Jan 01 2026 $maintainer - $version-$release_num
- Packaged from the $topdir release tarball.
SPEC

  rpmbuild --define "_topdir $_top" -bb "$_top/SPECS/reprobuild.spec" >"$stage/rpmbuild.log" 2>&1 || {
    log 'rpmbuild failed; last 40 lines:'
    tail -n 40 "$stage/rpmbuild.log" >&2
    die 'rpmbuild -bb failed'
  }
  _n=0
  for _r in "$_top/RPMS"/*/*.rpm; do
    [ -f "$_r" ] || continue
    cp "$_r" "$out/"
    log "built $out/$(basename "$_r")"
    _n=$((_n + 1))
  done
  [ "$_n" -gt 0 ] || die 'rpmbuild exited 0 but produced no .rpm'
}

# ---------------------------------------------------------------------
# .pkg.tar.zst (pacman)
# ---------------------------------------------------------------------
build_arch() {
  command -v bsdtar >/dev/null 2>&1 || command -v tar >/dev/null 2>&1 \
    || die 'no tar available'
  _root="$stage/arch"
  rm -rf "$_root"
  stage_tree "$_root" arch

  # A pacman package is a tar of the payload plus a .PKGINFO. Building it
  # directly (rather than via makepkg) is what lets the release pipeline
  # produce it on a NON-Arch runner: makepkg refuses to run as root and
  # needs an Arch userland, neither of which a release runner has.
  _size="$(du -sb "$_root" 2>/dev/null | awk '{print $1}')"
  [ -n "$_size" ] || _size=0
  _builddate="$(date -u +%s)"
  cat > "$_root/.PKGINFO" <<PKGINFO
pkgname = reprobuild
pkgbase = reprobuild
pkgver = $version-$release_num
pkgdesc = Reproducible build system
url = $homepage
builddate = $_builddate
packager = $maintainer
size = $_size
arch = $pkg_arch
license = Apache-2.0
PKGINFO

  _pkg="$out/reprobuild-${version}-${release_num}-${pkg_arch}.pkg.tar.zst"
  rm -f "$_pkg"
  if command -v bsdtar >/dev/null 2>&1; then
    # `-f "$_pkg"`, NOT `-cf - ... > "$_pkg"`. When bsdtar compresses
    # internally AND writes to stdout it pads the COMPRESSED stream out to
    # its blocking factor (10240 bytes), so the file is a valid zstd frame
    # followed by NUL padding. libzstd rejects that trailing garbage as
    # "Unknown frame descriptor", and the whole arch channel dies at
    # `repo-add`:
    #
    #   bsdtar: Error opening archive: Zstd decompression failed: Unknown
    #           frame descriptor
    #   ==> ERROR: '...pkg.tar.zst' is not a package file, skipping
    #
    # Writing to a named file applies the blocking to the tar stream
    # instead, before compression, which is where it belongs. This was
    # found by m3_install_pacman.sh, the first thing ever to run this
    # function; every .pkg.tar.zst built before that fix was unreadable.
    # `usr`, NOT `./usr`. libalpm records member names verbatim, and with a
    # `./` prefix it matches NOTHING: pacman prints "installing reprobuild",
    # exits 0, writes a local database entry -- and installs ZERO FILES.
    # `pacman -Ql reprobuild` comes back empty and /usr/bin/repro does not
    # exist. That is a package that installs cleanly and provides nothing,
    # the same shape as this campaign's rpm `%files` glob defect, and it
    # was found by m3_install_pacman.sh's assertion on the INSTALLED
    # PAYLOAD rather than on the package manager's exit code.
    ( cd "$_root" && bsdtar --zstd -cf "$_pkg" .PKGINFO usr ) \
      || die 'bsdtar failed building the pacman package'
  else
    command -v zstd >/dev/null 2>&1 || die 'need bsdtar or zstd to build a .pkg.tar.zst'
    ( cd "$_root" && tar -cf - .PKGINFO usr | zstd -q -o "$_pkg" -f ) \
      || die 'tar|zstd failed building the pacman package'
  fi
  [ -s "$_pkg" ] || die "built an empty $_pkg"
  # READ IT BACK. A package that cannot be listed is a package pacman
  # cannot install, and the failure otherwise surfaces two scripts later
  # inside repo-add, where it looks like a signing problem. Checked with
  # whichever reader is present, because the writer being able to read its
  # own output is exactly what was NOT true above.
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -tf "$_pkg" > "$stage/arch-listing.txt" 2>/dev/null \
      || die "the package $_pkg cannot be read back (bsdtar -tf failed); pacman would reject it as 'not a package file'"
    grep -q '^\.PKGINFO$' "$stage/arch-listing.txt" \
      || die "the package $_pkg has no .PKGINFO member; pacman would reject it as 'not a package file'"
    # The payload must be present under a BARE `usr/` prefix. Both halves
    # are asserted, because a `./usr/` prefix reads back fine and still
    # installs nothing.
    grep -q '^usr/bin/' "$stage/arch-listing.txt" \
      || die "the package $_pkg has no usr/bin/ member; pacman would install it and provide nothing"
    if grep -q '^\./' "$stage/arch-listing.txt"; then
      die "the package $_pkg has './'-prefixed members; libalpm matches them against nothing and would install ZERO files while reporting success"
    fi
  elif command -v zstd >/dev/null 2>&1; then
    zstd -t "$_pkg" >/dev/null 2>&1 \
      || die "the package $_pkg is not a valid zstd stream; pacman would reject it"
  fi
  log "built $_pkg"
}

# ---------------------------------------------------------------------
# .pkg (macOS component package)
# ---------------------------------------------------------------------
# A flat component package whose payload is rooted at /, holding the archive
# tree under /usr/local/lib/reprobuild, a wrapper per public command in
# /usr/local/bin, and the completion files (stage_tree, format `pkg`). It is
# built with pkgbuild, which exists on macOS only, so this ecosystem is never
# part of `all`. The package is unsigned and not notarized.
#
# Why /usr/local: macOS's /usr is read-only, and /usr/local is where its
# installers put third-party programs and what its shells already look at:
# measured on macOS 26 (Apple silicon), /bin/zsh's default fpath starts with
# /usr/local/share/zsh/site-functions. bash-completion searches
# /usr/local/share/bash-completion/completions by default (XDG_DATA_DIRS
# unset), but macOS's own bash is 3.2 and ships none. Fish searches
# /usr/local/share/fish/vendor_completions.d only when its own prefix is
# /usr/local (Homebrew on Intel) or XDG_DATA_DIRS names /usr/local/share.
build_pkg() {
  command -v pkgbuild >/dev/null 2>&1 || die 'pkgbuild not found (the macOS .pkg can be built on macOS only)'
  _root="$stage/pkgroot"
  rm -rf "$_root"
  mkdir -p "$_root"
  stage_tree "$_root" pkg
  # Extended attributes on the staged files (quarantine marks from wherever
  # the archive was unpacked) would travel in the payload as `._name`
  # AppleDouble records. Clear what can be cleared; macOS refuses to clear its
  # own provenance mark, and the installer applies the rest as attributes.
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$_root" 2>/dev/null || true
  fi
  _pkg="$out/reprobuild-${version}-${platform}-${asset_arch}.pkg"
  rm -f "$_pkg"
  # --ownership recommended: root:wheel on install, whoever built the tree.
  pkgbuild --root "$_root" --identifier "${REPRO_PKG_IDENTIFIER:-com.metacraft-labs.reprobuild}" \
    --version "$version" --install-location / --ownership recommended \
    "$_pkg" >"$stage/pkgbuild.log" 2>&1 || {
    log 'pkgbuild failed; last 40 lines:'
    tail -n 40 "$stage/pkgbuild.log" >&2
    die 'pkgbuild failed'
  }
  [ -s "$_pkg" ] || die "built an empty $_pkg"
  # READ IT BACK, as the pacman package is: the payload must hold the command
  # and the completion files, or the installer would run and provide nothing.
  command -v pkgutil >/dev/null 2>&1 || die 'pkgutil not found; cannot read the package back'
  pkgutil --payload-files "$_pkg" > "$stage/pkg-listing.txt" 2>/dev/null \
    || die "the package $_pkg cannot be read back (pkgutil --payload-files failed)"
  for _want in ./usr/local/bin/repro \
      ./usr/local/share/bash-completion/completions/repro \
      ./usr/local/share/zsh/site-functions/_repro \
      ./usr/local/share/fish/vendor_completions.d/repro.fish ; do
    grep -qx -- "$_want" "$stage/pkg-listing.txt" \
      || die "the package $_pkg has no $_want in its payload"
  done
  log "built $_pkg"
}

built=0
if want deb;  then build_deb;  built=$((built + 1)); fi
if want rpm;  then build_rpm;  built=$((built + 1)); fi
if want arch; then build_arch; built=$((built + 1)); fi
# Only on request: see build_pkg.
if [ "$ecosystem" = pkg ]; then build_pkg; built=$((built + 1)); fi

[ "$built" -gt 0 ] || die "--ecosystem $ecosystem selected nothing to build"
log "done: $built ecosystem(s) into $out"
ls -la "$out" >&2
: "$BP_SELF_DIR"
