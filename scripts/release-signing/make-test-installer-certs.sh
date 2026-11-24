#!/bin/sh
# Generate THROWAWAY ("stand-in") certificates for signing the macOS .pkg and
# the Windows MSI, for one run.
#
#   make-test-installer-certs.sh --dir <scratch-dir> [--unmarked]
#
# Writes into <scratch-dir> (created mode 0700; it must be empty or absent):
#
#   pkg-root.pem                the stand-in root CA (public)
#   pkg-ca.pem                  an intermediate shaped like Apple's
#                               "Developer ID Certification Authority" (public)
#   pkg-signer.pem              the leaf, shaped like a "Developer ID
#                               Installer" certificate (public)
#   pkg-signer.p12              the leaf, its private key and the intermediate
#   pkg-signer.p12.password     the random password of pkg-signer.p12
#   authenticode.pem            a self-signed Authenticode code-signing
#                               certificate (public; it is its own root)
#   authenticode.pfx            that certificate and its private key
#   authenticode.pfx.password   the random password of authenticode.pfx
#
# and prints nothing else on stdout. The private keys exist only inside the
# two password-protected containers in <scratch-dir>; the loose key files
# openssl needs while issuing are removed before the script returns. Nothing
# here is ever committed, uploaded or imported into a certificate store or a
# keychain by this script: the caller deletes <scratch-dir> when the run ends.
#
# ## The marker
#
# Every subject carries O=REPROBUILD UNTRUSTED TEST CERTIFICATE, the X.509
# counterpart of the OpenPGP test-key marker (make-test-key.sh). That marker
# is what makes repro-sign-installer.sh classify a certificate as a TEST
# certificate, which it signs with only under REPRO_SIGNING_ALLOW_TEST_KEY=1,
# never on a publishing run, and always with a marker file beside the asset.
# `--unmarked` leaves the marker out; it exists for the tests that must show
# what the production path does with a certificate that no platform trusts
# (it signs, then the platform-trust verification refuses it).
#
# ## The shapes, and where they come from
#
# The .pkg chain mirrors Apple's Developer ID chain (root -> Developer ID
# Certification Authority -> Developer ID Installer leaf), with Apple's object
# identifiers, as published in Apple's certificate policies
# (https://www.apple.com/certificateauthority/, the Developer ID CPS) and as
# listed by apple-codesign (`rcodesign x509-oids`,
# https://gregoryszorc.com/docs/apple-codesign/main/):
#
#   1.2.840.113635.100.6.2.6   on the intermediate: a Developer ID CA
#   1.2.840.113635.100.4.13    extended key usage: Developer ID Installer
#   1.2.840.113635.100.6.1.14  on the leaf (critical): Developer ID Installer
#
# The leaf's subject follows Apple's form, "Developer ID Installer: <name>
# (<team id>)" with the team identifier in OU and UID. The stand-in's team,
# TESTTEAM01, is a placeholder of the same length; the tooling reads the
# marker in O, never the team, to tell a stand-in from a real certificate.
#
# The Authenticode certificate is self-signed, with the code-signing extended
# key usage (1.3.6.1.5.5.7.3.3, RFC 5280 section 4.2.1.12), digitalSignature
# and CA:FALSE: Authenticode
# (https://learn.microsoft.com/windows-hardware/drivers/install/authenticode)
# requires the code-signing usage of the signer certificate.
#
# Passwords reach openssl on stdin (never `file:`, which Git for Windows'
# native openssl would be handed as an unconverted MSYS path).
#
# Both containers use PBE-SHA1-3DES and a SHA-1 MAC rather than OpenSSL 3's
# AES-256 default, because macOS's `security import` and older Windows
# certificate loaders reject the newer PKCS#12 encoding.

set -eu

dir=''
marked=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --unmarked) marked=0; shift ;;
    -h|--help) sed -n '2,62p' "$0"; exit 0 ;;
    *) printf 'make-test-installer-certs: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

die() { printf 'make-test-installer-certs: %s\n' "$*" >&2; exit 1; }

[ -n "$dir" ] || die '--dir is required'
command -v openssl >/dev/null 2>&1 || die 'openssl is not on PATH'
if [ -e "$dir" ]; then
  [ -d "$dir" ] || die "$dir exists and is not a directory"
  [ -z "$(ls -A "$dir")" ] || die "$dir is not empty; refusing to mix certificates of two runs"
fi

umask 077
mkdir -p "$dir"
chmod 700 "$dir"

marker='REPROBUILD UNTRUSTED TEST CERTIFICATE'
if [ "$marked" -eq 1 ]; then
  org="$marker"
else
  org='Reprobuild Unmarked Test Certificate'
fi

# openssl -subj treats '/' and '=' as separators; none of these values hold
# either, and none is longer than the 64 characters X.520 allows for CN.
# Under Git for Windows' bash, the MSYS2 runtime rewrites an argument that
# starts with '/' into a Windows path before it reaches the native openssl.exe
# ("/O=..." would arrive as "C:/Program Files/Git/O=..."), so the subjects'
# prefixes are excluded from that conversion; the file paths still convert.
# MSYS2_ARG_CONV_EXCL is a ';'-separated list of argument prefixes
# (https://www.msys2.org/docs/filesystem-paths/); elsewhere it is inert.
MSYS2_ARG_CONV_EXCL="/O=;/UID=${MSYS2_ARG_CONV_EXCL:+;$MSYS2_ARG_CONV_EXCL}"
export MSYS2_ARG_CONV_EXCL
root_subj="/O=$org/CN=Reprobuild Stand-in Root CA"
ca_subj="/O=$org/CN=Reprobuild Stand-in Developer ID Certification Authority"
leaf_subj="/UID=TESTTEAM01/CN=Developer ID Installer: Reprobuild Stand-in (TESTTEAM01)/OU=TESTTEAM01/O=$org/C=XX"
ac_subj="/O=$org/CN=Reprobuild Stand-in Authenticode"

work="$dir/.issue"
mkdir "$work"
# The loose private keys live in $work only while they are being used.
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM

rand_hex() { openssl rand -hex "$1"; }
quiet() { "$@" >"$work/openssl.log" 2>&1 || { cat "$work/openssl.log" >&2; die "openssl failed: $1 $2"; }; }

# ── the .pkg chain ───────────────────────────────────────────────────
quiet openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 2 \
  -keyout "$work/root.key" -out "$dir/pkg-root.pem" -subj "$root_subj" \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -addext 'subjectKeyIdentifier=hash'

cat > "$work/ca.ext" <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
1.2.840.113635.100.6.2.6=DER:05:00
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
quiet openssl req -new -newkey rsa:3072 -nodes -keyout "$work/ca.key" \
  -out "$work/ca.csr" -subj "$ca_subj"
quiet openssl x509 -req -sha256 -days 2 -in "$work/ca.csr" \
  -CA "$dir/pkg-root.pem" -CAkey "$work/root.key" -set_serial "0x$(rand_hex 16)" \
  -extfile "$work/ca.ext" -out "$dir/pkg-ca.pem"

cat > "$work/leaf.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,1.2.840.113635.100.4.13
1.2.840.113635.100.6.1.14=critical,DER:05:00
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
quiet openssl req -new -newkey rsa:2048 -nodes -keyout "$work/leaf.key" \
  -out "$work/leaf.csr" -subj "$leaf_subj"
quiet openssl x509 -req -sha256 -days 2 -in "$work/leaf.csr" \
  -CA "$dir/pkg-ca.pem" -CAkey "$work/ca.key" -set_serial "0x$(rand_hex 16)" \
  -extfile "$work/leaf.ext" -out "$dir/pkg-signer.pem"

rand_hex 24 > "$dir/pkg-signer.p12.password"
quiet openssl pkcs12 -export -name 'Reprobuild Stand-in Developer ID Installer' \
  -inkey "$work/leaf.key" -in "$dir/pkg-signer.pem" -certfile "$dir/pkg-ca.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout stdin -out "$dir/pkg-signer.p12" < "$dir/pkg-signer.p12.password"

# ── the Authenticode certificate ─────────────────────────────────────
quiet openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 2 \
  -keyout "$work/ac.key" -out "$dir/authenticode.pem" -subj "$ac_subj" \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=critical,codeSigning' \
  -addext 'subjectKeyIdentifier=hash'

rand_hex 24 > "$dir/authenticode.pfx.password"
quiet openssl pkcs12 -export -name 'Reprobuild Stand-in Authenticode' \
  -inkey "$work/ac.key" -in "$dir/authenticode.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout stdin -out "$dir/authenticode.pfx" < "$dir/authenticode.pfx.password"

# The intermediate's and root's keys are not kept: nothing may issue a second
# certificate under this run's root.
