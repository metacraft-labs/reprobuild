#!/bin/sh
# Build and sign an apt repository so that apt verifies it NATIVELY.
#
#   repro-sign-apt-repo.sh --root <repo-root> --key <key-spec>
#                          [--suite stable] [--component main]
#                          [--arch amd64] [--origin Reprobuild]
#                          [--export-key <path>]
#
# <repo-root> must already contain pool/<component>/*.deb.
#
# Emits:
#   dists/<suite>/<component>/binary-<arch>/Packages{,.gz}
#   dists/<suite>/Release            unsigned, canonical
#   dists/<suite>/InRelease          clearsigned Release   <- apt prefers
#   dists/<suite>/Release.gpg        detached sig over Release
#   reprobuild-archive-keyring.gpg   (with --export-key) for signed-by=
#   reprobuild.sources               a deb822 stanza the client can drop in
#
# ## Why BOTH InRelease and Release.gpg
#
# apt fetches InRelease first and falls back to Release + Release.gpg.
# Shipping only InRelease works with every apt in support, but a mirror
# or proxy that rewrites text files (some do, for line endings) breaks a
# clearsigned file while leaving a detached signature intact, and vice
# versa a mirror that drops unknown files breaks the detached pair. The
# two together mean a client is never left with a repo it must trust
# unverified. `apt-secure(8)` documents the fallback order.
#
# ## What apt actually checks, and therefore what tampering it catches
#
# InRelease/Release carry SHA256 over each Packages index; each Packages
# stanza carries SHA256 over its .deb. That is a hash chain rooted in
# ONE signature. So:
#
#   * tamper a .deb              -> apt: "Hash Sum mismatch" on download
#   * tamper Packages            -> apt: "Hash Sum mismatch" on update
#   * tamper Release/InRelease   -> apt: "BADSIG"/"The following
#                                   signatures were invalid"
#
# all three from apt itself, with a non-zero exit. There is nothing for
# reprobuild to check at install time on an apt system, which is the
# point of signing the repository rather than only the artifacts.

set -eu

RS_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
export RS_LIB_DIR
# shellcheck source=./lib-signing.sh
. "$RS_LIB_DIR/lib-signing.sh"

root=''; key=''; suite='stable'; component='main'; arch='amd64'
origin='Reprobuild'; label='Reprobuild'; export_key_to=''

while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --suite) suite="$2"; shift 2 ;;
    --component) component="$2"; shift 2 ;;
    --arch) arch="$2"; shift 2 ;;
    --origin) origin="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --export-key) export_key_to="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) rs_die "unknown argument: $1" ;;
  esac
done

[ -n "$root" ] || rs_die '--root is required'
[ -d "$root" ] || rs_die "--root $root is not a directory"
[ -n "$key" ]  || rs_die '--key is required'
[ -n "${GNUPGHOME:-}" ] || rs_die 'GNUPGHOME must point at the home holding the signing key; this script will not use ~/.gnupg'

command -v dpkg-scanpackages >/dev/null 2>&1 \
  || rs_die 'dpkg-scanpackages not found (install dpkg-dev)'
command -v apt-ftparchive >/dev/null 2>&1 \
  || rs_die 'apt-ftparchive not found (install apt-utils)'

class="$(rs_require_signing_key "$key")"
rs_log "apt repo signing, key class=$class"

pool_debs="$(find "$root/pool" -name '*.deb' 2>/dev/null | wc -l | tr -d ' ')"
[ "$pool_debs" -gt 0 ] \
  || rs_die "no .deb under $root/pool; refusing to sign an empty index"

bindir="dists/$suite/$component/binary-$arch"
mkdir -p "$root/$bindir"

( cd "$root" && dpkg-scanpackages --multiversion pool /dev/null ) \
  > "$root/$bindir/Packages" \
  || rs_die 'dpkg-scanpackages failed'
stanzas="$(grep -c '^Package: ' "$root/$bindir/Packages" || true)"
[ "$stanzas" -eq "$pool_debs" ] \
  || rs_die "Packages has $stanzas stanza(s) but pool has $pool_debs .deb; the index does not describe the pool"
gzip -9nkf "$root/$bindir/Packages" 2>/dev/null \
  || { gzip -9nc "$root/$bindir/Packages" > "$root/$bindir/Packages.gz"; }
rs_log "indexed $stanzas package(s) into $bindir/Packages"

# apt-ftparchive computes the per-index hashes that root the chain.
( cd "$root" && apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=$origin" \
    -o "APT::FTPArchive::Release::Label=$label" \
    -o "APT::FTPArchive::Release::Suite=$suite" \
    -o "APT::FTPArchive::Release::Codename=$suite" \
    -o "APT::FTPArchive::Release::Architectures=$arch" \
    -o "APT::FTPArchive::Release::Components=$component" \
    -o "APT::FTPArchive::Release::Description=Reprobuild release channel" \
    release "dists/$suite" ) > "$root/dists/$suite/Release" \
  || rs_die 'apt-ftparchive release failed'

grep -q '^SHA256:' "$root/dists/$suite/Release" \
  || rs_die 'generated Release carries no SHA256 block; apt would have nothing to chain through'

rm -f "$root/dists/$suite/InRelease" "$root/dists/$suite/Release.gpg"
rs_clearsign "$key" "$root/dists/$suite/Release" "$root/dists/$suite/InRelease"
rs_detach_sign "$key" "$root/dists/$suite/Release"
mv "$root/dists/$suite/Release.asc" "$root/dists/$suite/Release.gpg"

grep -q -- '-----BEGIN PGP SIGNATURE-----' "$root/dists/$suite/InRelease" \
  || rs_die 'InRelease carries no signature block'
[ -s "$root/dists/$suite/Release.gpg" ] \
  || rs_die 'Release.gpg is empty'
rs_log "signed dists/$suite/{InRelease,Release.gpg}"

if [ -n "$export_key_to" ]; then
  # A BINARY keyring, not armoured: `signed-by=` accepts both, but the
  # binary form is what every apt in support reads without ambiguity,
  # and it is what /usr/share/keyrings/*.gpg holds.
  rs_gpg --export "$key" > "$export_key_to" || rs_die 'gpg --export failed'
  [ -s "$export_key_to" ] || rs_die "exported keyring $export_key_to is empty"
  rs_log "exported binary keyring to $export_key_to"

  cat > "$root/reprobuild.sources" <<SOURCES
Types: deb
URIs: file://$root
Suites: $suite
Components: $component
Architectures: $arch
Signed-By: $export_key_to
SOURCES
  rs_log "wrote $root/reprobuild.sources (deb822, Signed-By pinned)"
fi
