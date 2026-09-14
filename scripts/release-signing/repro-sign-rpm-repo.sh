#!/bin/sh
# Build and sign an rpm repository so that dnf verifies it NATIVELY.
#
#   repro-sign-rpm-repo.sh --root <repo-root> --key <key-spec>
#                          [--id reprobuild] [--export-key <path>]
#
# <repo-root> must already contain the .rpm files.
#
# Emits:
#   <each>.rpm                    with an OpenPGP header signature
#   repodata/repomd.xml           createrepo_c metadata
#   repodata/repomd.xml.asc       detached signature over it
#   RPM-GPG-KEY-<id>              armoured public key
#   <id>.repo                     yum/dnf client config, gpgcheck=1
#                                 AND repo_gpgcheck=1
#
# ## Two independent checks, and dnf needs BOTH switched on
#
# `gpgcheck=1` makes rpm verify the signature INSIDE each package
# header. `repo_gpgcheck=1` makes dnf verify repomd.xml.asc over the
# repository index. They catch different tampering and neither implies
# the other:
#
#   * a tampered .rpm with intact metadata  -> caught only by gpgcheck
#   * a tampered repomd.xml                 -> caught only by
#                                              repo_gpgcheck
#
# Fedora's own repos historically shipped repo_gpgcheck=0, which is why
# writing the .repo file is part of SIGNING here rather than left to the
# consumer: a correctly signed repository consumed with the check off is
# an unsigned repository.
#
# ## Why the key is exported armoured, unlike apt's
#
# rpm's `gpgkey=` fetches an armoured block and feeds it to
# `rpm --import`. apt's `Signed-By=` reads a binary keyring. Each
# ecosystem's native form, deliberately -- converting either to the
# other's shape is how "the key is there but the manager ignores it"
# happens.

set -eu

RS_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
export RS_LIB_DIR
# shellcheck source=./lib-signing.sh
. "$RS_LIB_DIR/lib-signing.sh"

root=''; key=''; repo_id='reprobuild'; export_key_to=''

while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --id) repo_id="$2"; shift 2 ;;
    --export-key) export_key_to="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) rs_die "unknown argument: $1" ;;
  esac
done

[ -n "$root" ] || rs_die '--root is required'
[ -d "$root" ] || rs_die "--root $root is not a directory"
[ -n "$key" ]  || rs_die '--key is required'
[ -n "${GNUPGHOME:-}" ] || rs_die 'GNUPGHOME must point at the home holding the signing key'

command -v createrepo_c >/dev/null 2>&1 || rs_die 'createrepo_c not found'
command -v rpmsign >/dev/null 2>&1 || rs_die 'rpmsign not found (install rpm-sign)'
command -v rpm >/dev/null 2>&1 || rs_die 'rpm not found'

class="$(rs_require_signing_key "$key")"
fpr="$(rs_fingerprint_of "$key")"
rs_log "rpm repo signing, key class=$class"

rpm_count="$(find "$root" -maxdepth 2 -name '*.rpm' | wc -l | tr -d ' ')"
[ "$rpm_count" -gt 0 ] || rs_die "no .rpm under $root; refusing to sign an empty repository"

# ── 1. Sign each package's header ────────────────────────────────────
#
# rpmsign shells out to gpg itself, through the %__gpg_sign_cmd macro.
# It must see the SAME ephemeral GNUPGHOME, so it is passed explicitly
# rather than relied on from the environment (rpm resets parts of the
# environment for the signing child).

signed=0
for f in $(find "$root" -maxdepth 2 -name '*.rpm' | LC_ALL=C sort); do
  # _gpg_name + _gpg_path only. The distro's own %__gpg_sign_cmd is
  # left alone deliberately: overriding it looked like belt-and-braces
  # and was in fact the first thing to break here, because rpm 6.0's
  # macro passes the argv through %{shescape} and quotes positional
  # placeholders that an older hand-written override does not have.
  # The key is unprotected, so the default command needs no passphrase
  # plumbing.
  rpmsign \
    --define "_gpg_name $fpr" \
    --define "_gpg_path $GNUPGHOME" \
    --addsign "$f" >/dev/null 2>&1 \
    || rs_die "rpmsign --addsign failed for $f"
  # Assert the header really carries a signature now, rather than
  # trusting rpmsign's exit code: a macro-expansion problem can leave
  # it exiting 0 having signed nothing, which would be a silently
  # unsigned release. `rpm -Kv` names the signature whether or not the
  # key is in rpm's keyring, so this assertion does not smuggle in a
  # trust check it cannot make here.
  if ! rpm -Kv "$f" 2>&1 | grep -qi 'openpgp.*signature'; then
    rs_die "$f has no OpenPGP header signature after rpmsign"
  fi
  signed=$((signed + 1))
done
[ "$signed" -eq "$rpm_count" ] \
  || rs_die "found $rpm_count rpm(s) but signed $signed"
rs_log "signed $signed rpm header(s)"

# ── 2. Metadata + its detached signature ─────────────────────────────

rm -rf "$root/repodata"
createrepo_c --quiet "$root" || rs_die 'createrepo_c failed'
[ -f "$root/repodata/repomd.xml" ] || rs_die 'createrepo_c produced no repomd.xml'

rs_detach_sign "$key" "$root/repodata/repomd.xml"
[ -s "$root/repodata/repomd.xml.asc" ] || rs_die 'repomd.xml.asc is empty'
rs_log 'signed repodata/repomd.xml -> repomd.xml.asc'

# ── 3. Key + client config ───────────────────────────────────────────

keyfile="${export_key_to:-$root/RPM-GPG-KEY-$repo_id}"
rs_gpg --armor --export "$key" > "$keyfile" || rs_die 'gpg --export failed'
[ -s "$keyfile" ] || rs_die "exported key $keyfile is empty"
grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$keyfile" \
  || rs_die "$keyfile is not an armoured public key block"

cat > "$root/$repo_id.repo" <<REPOFILE
[$repo_id]
name=Reprobuild
baseurl=file://$root
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$keyfile
REPOFILE
rs_log "wrote $root/$repo_id.repo (gpgcheck=1 repo_gpgcheck=1)"
