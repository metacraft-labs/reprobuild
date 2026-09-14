#!/bin/sh
# Build and sign a pacman repository so that pacman verifies it
# NATIVELY.
#
#   repro-sign-pacman-repo.sh --root <repo-root> --key <key-spec>
#                             [--db reprobuild] [--export-key <path>]
#
# <repo-root> must already contain the *.pkg.tar.* files.
#
# Emits:
#   <pkg>.pkg.tar.zst.sig      detached, BINARY signature per package
#   <db>.db.tar.gz             + <db>.db.tar.gz.sig
#   <db>.files.tar.gz          + <db>.files.tar.gz.sig
#   <db>.db / <db>.files       the symlinks pacman actually fetches
#   reprobuild.pacman.conf     a [repo] stanza with
#                              SigLevel = Required DatabaseRequired
#
# ## The three signatures pacman can be made to require
#
#   SigLevel = Required          -> every PACKAGE must carry a valid sig
#   SigLevel = DatabaseRequired  -> the DATABASE must carry a valid sig
#
# Arch's own default is `Required DatabaseOptional`, i.e. the sync db is
# NOT verified by default. A repository that signs its packages but not
# its db is one MITM away from having a package removed or downgraded
# without detection, so this script signs both and the emitted stanza
# asks for both. Signing only what the default happens to check would
# be signing for appearance.
#
# ## Why the signatures are BINARY, not armoured
#
# pacman's `.sig` files are raw OpenPGP packets; libalpm feeds them to
# gpgme directly and an armoured file is rejected as malformed. This is
# the one place in this directory that does NOT use --armor, and it is
# not a style choice.

set -eu

RS_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
export RS_LIB_DIR
# shellcheck source=./lib-signing.sh
. "$RS_LIB_DIR/lib-signing.sh"

root=''; key=''; dbname='reprobuild'; export_key_to=''

while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --db) dbname="$2"; shift 2 ;;
    --export-key) export_key_to="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) rs_die "unknown argument: $1" ;;
  esac
done

[ -n "$root" ] || rs_die '--root is required'
[ -d "$root" ] || rs_die "--root $root is not a directory"
[ -n "$key" ]  || rs_die '--key is required'
[ -n "${GNUPGHOME:-}" ] || rs_die 'GNUPGHOME must point at the home holding the signing key'

command -v repo-add >/dev/null 2>&1 || rs_die 'repo-add not found (install pacman)'

class="$(rs_require_signing_key "$key")"
fpr="$(rs_fingerprint_of "$key")"
rs_log "pacman repo signing, key class=$class"

pkgs="$(find "$root" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' | LC_ALL=C sort)"
pkg_count="$(printf '%s\n' "$pkgs" | grep -c . || true)"
[ "$pkg_count" -gt 0 ] || rs_die "no *.pkg.tar.* under $root; refusing to sign an empty repository"

# ── 1. Per-package detached signatures (binary) ──────────────────────

signed=0
for p in $pkgs; do
  rm -f "$p.sig"
  rs_gpg --local-user "$key" --detach-sign --no-armor --output "$p.sig" "$p" \
    || rs_die "gpg --detach-sign failed for $p"
  [ -s "$p.sig" ] || rs_die "empty signature for $p"
  # A binary OpenPGP signature must NOT start with the armour header.
  if head -c 5 "$p.sig" | grep -q -- '-----'; then
    rs_die "$p.sig is ASCII-armoured; pacman will reject it as malformed"
  fi
  signed=$((signed + 1))
done
[ "$signed" -eq "$pkg_count" ] || rs_die "found $pkg_count package(s) but signed $signed"
rs_log "signed $signed package(s)"

# ── 2. The database, signed by repo-add itself ───────────────────────
#
# repo-add --sign --key <fpr> shells out to gpg, so it needs the same
# GNUPGHOME. It is exported above and inherited here.

rm -f "$root/$dbname.db"* "$root/$dbname.files"*
( cd "$root" && repo-add --sign --key "$fpr" "$dbname.db.tar.gz" $(printf '%s\n' $pkgs | while IFS= read -r p; do printf '%s ' "${p##*/}"; done) ) >/dev/null 2>"$root/.repo-add.log" \
  || { cat "$root/.repo-add.log" >&2; rs_die 'repo-add --sign failed'; }

for f in "$dbname.db.tar.gz" "$dbname.files.tar.gz"; do
  [ -f "$root/$f" ] || rs_die "repo-add produced no $f"
  [ -s "$root/$f.sig" ] || rs_die "repo-add produced no signature for $f"
done
rs_log "signed $dbname.db.tar.gz and $dbname.files.tar.gz"

# pacman fetches <db>.db, not <db>.db.tar.gz, and it fetches <db>.db.sig
# beside it. repo-add makes the first pair of symlinks; the .sig links
# are ours, and their absence is exactly how "DatabaseRequired is on but
# nothing is checked" happens.
( cd "$root" \
  && ln -sf "$dbname.db.tar.gz" "$dbname.db" \
  && ln -sf "$dbname.db.tar.gz.sig" "$dbname.db.sig" \
  && ln -sf "$dbname.files.tar.gz" "$dbname.files" \
  && ln -sf "$dbname.files.tar.gz.sig" "$dbname.files.sig" )
for l in "$dbname.db" "$dbname.db.sig" "$dbname.files" "$dbname.files.sig"; do
  [ -e "$root/$l" ] || rs_die "$l is missing or dangling"
done

# ── 3. Key + client config ───────────────────────────────────────────

keyfile="${export_key_to:-$root/reprobuild-pacman.key}"
rs_gpg --armor --export "$key" > "$keyfile" || rs_die 'gpg --export failed'
[ -s "$keyfile" ] || rs_die "exported key $keyfile is empty"

cat > "$root/reprobuild.pacman.conf" <<CONF
[$dbname]
SigLevel = Required DatabaseRequired
Server = file://$root
CONF
rs_log "wrote $root/reprobuild.pacman.conf (SigLevel = Required DatabaseRequired)"
rs_log "import with: pacman-key --add $keyfile && pacman-key --lsign-key $fpr"
