#!/usr/bin/env python3
"""Verify the signature of a flat macOS installer package (.pkg) against a
given root certificate, without macOS.

    verify-xar-signature.py <package.pkg> --trust-root <root.pem>
    verify-xar-signature.py <package.pkg> --print-signer

A flat package is a XAR archive
(https://github.com/apple-oss-distributions/xar, xar/include/xar.h.in and
xar/lib/signature.c): a 28-byte big-endian header, a zlib-compressed XML table
of contents (TOC), then the heap. The TOC names, by offset and size in the
heap, a checksum of the COMPRESSED TOC bytes and the signatures over that
checksum:

* `<signature style="RSA">`: an RSA PKCS#1 v1.5 signature whose certificate
  chain is in the element's `KeyInfo/X509Data` (the signer is the certificate
  whose key verifies it; xar and productsign list it first). xar's own signer
  signs the checksum as a digest of the TOC's checksum algorithm; apple-codesign
  (`rcodesign sign`) signs SHA-256 over the checksum bytes. Either form is
  accepted, and which one verified is printed.
* `<x-signature style="CMS">`, when present: a detached CMS SignedData over the
  checksum bytes (what current pkgbuild/productsign and rcodesign add).

Every file's data in the heap carries its own checksum in the TOC, so the
signature over the TOC covers the payload through them; this verifier checks
each one too, which is what makes a changed payload byte fail here and not only
at installation.

What it checks, all of which must hold (exit 0), else exit 1 with the reason:

1. the stored TOC checksum equals the checksum of the compressed TOC;
2. every file's archived data matches its archived checksum;
3. the RSA signature verifies under the leaf certificate's key;
4. the leaf chains to --trust-root through the certificates the package
   carries (`openssl verify`), and carries Apple's Developer ID Installer
   extended key usage, 1.2.840.113635.100.4.13;
5. the CMS signature, if present, verifies over the checksum and chains to
   --trust-root, and its signer is the same certificate as the RSA signature's.

Trust is ONLY --trust-root: no system store is consulted, so a package signed
by a stand-in root verifies against that root and against nothing else, and a
production package is verified against Apple's root by the caller passing it
(or, on macOS, by pkgutil and spctl, which use the system's trust).

`openssl verify` and `openssl cms` are run with `-ignore_critical`: Apple
marks its Developer ID Installer leaf extension (1.2.840.113635.100.6.1.14)
critical, and OpenSSL refuses any critical extension it does not know. The
extended key usage is checked explicitly instead (point 4).

`--print-signer` prints the subject (one line, RFC 2253) and SHA-256
fingerprint of every certificate the RSA signature carries, and checks
nothing; exit 3 when the package is not signed.

Requires python3 (stdlib only) and the `openssl` command line.
"""

import argparse
import base64
import hashlib
import os
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib

DSIG = "{http://www.w3.org/2000/09/xmldsig#}"
DEVELOPER_ID_INSTALLER_EKU = "1.2.840.113635.100.4.13"
# xar.h: XAR_CKSUM_NONE 0, SHA1 1, MD5 2, OTHER 3 (named by the TOC's style).
HEADER_ALGS = {0: None, 1: "sha1", 2: "md5"}


class Refused(Exception):
    pass


def openssl(*args, data=None):
    proc = subprocess.run(["openssl", *args], input=data, capture_output=True)
    return proc.returncode, proc.stdout, proc.stderr.decode("utf-8", "replace")


def read_package(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    if len(raw) < 28 or raw[:4] != b"xar!":
        raise Refused(f"{path} is not a XAR archive (no 'xar!' header)")
    _, header_size, _, toc_compressed, _, header_alg = struct.unpack(">4sHHQQI", raw[:28])
    toc_bytes = raw[header_size:header_size + toc_compressed]
    if len(toc_bytes) != toc_compressed:
        raise Refused(f"{path} is truncated inside its table of contents")
    try:
        toc = ET.fromstring(zlib.decompress(toc_bytes))
    except (zlib.error, ET.ParseError) as exc:
        raise Refused(f"{path}: unreadable table of contents ({exc})")
    heap = raw[header_size + toc_compressed:]
    return toc, toc_bytes, heap, header_alg


def heap_slice(heap, elem, what):
    try:
        off = int(elem.find("offset").text)
        size = int(elem.find("size").text)
    except (AttributeError, TypeError, ValueError):
        raise Refused(f"{what}: no offset/size in the table of contents")
    if off < 0 or size <= 0 or off + size > len(heap):
        raise Refused(f"{what}: offset {off} size {size} is outside the heap ({len(heap)} bytes)")
    return heap[off:off + size]


def checksum_algorithm(elem, header_alg):
    style = (elem.get("style") or "").lower()
    if style in ("sha1", "sha256", "sha512", "md5"):
        return style
    alg = HEADER_ALGS.get(header_alg)
    if alg is None:
        raise Refused(f"unsupported checksum algorithm (style '{style}', header {header_alg})")
    return alg


def certificates(sig_elem):
    certs = []
    for node in sig_elem.iter(DSIG + "X509Certificate"):
        try:
            certs.append(base64.b64decode("".join((node.text or "").split()), validate=True))
        except ValueError as exc:
            raise Refused(f"a KeyInfo certificate is not base64 ({exc})")
    if not certs:
        raise Refused("the RSA signature carries no certificate")
    return certs


def pem_of(der):
    rc, out, err = openssl("x509", "-inform", "DER", "-outform", "PEM", data=der)
    if rc != 0:
        raise Refused(f"a KeyInfo certificate is not X.509: {err.strip()}")
    return out


def subject_and_fingerprint(pem):
    rc, out, err = openssl("x509", "-noout", "-subject", "-nameopt", "RFC2253",
                           "-fingerprint", "-sha256", data=pem)
    if rc != 0:
        raise Refused(f"cannot read the signer certificate: {err.strip()}")
    subject = fpr = ""
    for line in out.decode().splitlines():
        if line.startswith("subject="):
            subject = line[len("subject="):].strip()
        elif "Fingerprint=" in line:
            fpr = line.split("=", 1)[1].strip().replace(":", "").lower()
    return subject, fpr


def verify_files(toc, heap):
    checked = 0
    for data in toc.iter("data"):
        cks = data.find("archived-checksum")
        if cks is None:
            # xar writes an archived checksum for every file's data, and it is
            # the only thing that binds the data to the signed TOC; data
            # without one would be unverified, so it is refused, not skipped.
            raise Refused("a file's data carries no archived checksum, so the signature does not cover it")
        alg = (cks.get("style") or "").lower()
        if alg not in ("sha1", "sha256", "sha512", "md5"):
            raise Refused(f"a file's archived checksum uses unsupported style '{alg}'")
        try:
            off = int(data.find("offset").text)
            length = int(data.find("length").text)
        except (AttributeError, TypeError, ValueError):
            raise Refused("a file's data has no offset/length")
        if off < 0 or length < 0 or off + length > len(heap):
            raise Refused("a file's data lies outside the heap")
        actual = hashlib.new(alg, heap[off:off + length]).hexdigest()
        if actual != (cks.text or "").strip().lower():
            raise Refused(f"a file's data does not match its archived {alg} checksum")
        checked += 1
    return checked


def verify(path, trust_root, require_eku=True):
    toc, toc_bytes, heap, header_alg = read_package(path)
    toc_root = toc.find("toc")
    if toc_root is None:
        raise Refused("no <toc> element")
    ck = toc_root.find("checksum")
    if ck is None:
        raise Refused("the table of contents has no checksum, so nothing can be signed")
    alg = checksum_algorithm(ck, header_alg)
    stored = heap_slice(heap, ck, "TOC checksum")
    if stored != hashlib.new(alg, toc_bytes).digest():
        raise Refused(f"the stored {alg} checksum does not match the table of contents")
    files = verify_files(toc_root, heap)

    sig = toc_root.find("signature")
    if sig is None:
        raise Refused("the package is not signed (no <signature> in its table of contents)")
    if (sig.get("style") or "") != "RSA":
        raise Refused(f"unsupported signature style '{sig.get('style')}'")
    signature = heap_slice(heap, sig, "RSA signature")
    chain = [pem_of(der) for der in certificates(sig)]

    with tempfile.TemporaryDirectory(prefix="verify-xar-") as tmp:
        def put(name, data):
            p = os.path.join(tmp, name)
            with open(p, "wb") as fh:
                fh.write(data)
            return p

        cksum = put("checksum.bin", stored)
        sigfile = put("signature.bin", signature)

        # The signer is the certificate whose key verifies the signature.
        # xar and productsign list it first, but nothing in the format
        # requires that order, so every listed certificate is tried.
        def verifies(index):
            cert = put(f"cert{index}.pem", chain[index])
            rc, pub, _ = openssl("x509", "-in", cert, "-noout", "-pubkey")
            if rc != 0:
                return None
            pubfile = put(f"pub{index}.pem", pub)
            forms = []
            if len(stored) == hashlib.new(alg).digest_size:
                forms.append(("xar: PKCS#1 over the checksum as a " + alg + " digest",
                              ["pkeyutl", "-verify", "-pubin", "-inkey", pubfile,
                               "-pkeyopt", "digest:" + alg, "-in", cksum, "-sigfile", sigfile]))
            for dg in ("sha256", "sha1"):
                forms.append((f"{dg} over the checksum",
                              ["dgst", "-" + dg, "-verify", pubfile, "-signature", sigfile, cksum]))
            for name, cmd in forms:
                if openssl(*cmd)[0] == 0:
                    return name
            return None

        signer_index = verified_form = None
        for i in range(len(chain)):
            verified_form = verifies(i)
            if verified_form:
                signer_index = i
                break
        if signer_index is None:
            raise Refused("the RSA signature does not verify under the key of any certificate it carries")
        leaf = put("leaf.pem", chain[signer_index])
        others = [c for i, c in enumerate(chain) if i != signer_index]
        inter = put("chain.pem", b"".join(others) or chain[signer_index])

        verify_cmd = ["verify", "-ignore_critical", "-CAfile", trust_root]
        if others:
            verify_cmd += ["-untrusted", inter]
        rc, out, err = openssl(*verify_cmd, leaf)
        if rc != 0:
            raise Refused("the signer certificate does not chain to the trust root: "
                          + (out.decode() + err).strip().replace("\n", " | "))
        if require_eku:
            rc, out, err = openssl("x509", "-in", leaf, "-noout", "-ext", "extendedKeyUsage")
            if DEVELOPER_ID_INSTALLER_EKU not in out.decode():
                raise Refused("the signer certificate lacks the Developer ID Installer extended "
                              f"key usage ({DEVELOPER_ID_INSTALLER_EKU})")

        cms_note = "no CMS signature in the package"
        xsig = toc_root.find("x-signature")
        if xsig is not None:
            if (xsig.get("style") or "") != "CMS":
                raise Refused(f"unsupported x-signature style '{xsig.get('style')}'")
            cms = put("cms.der", heap_slice(heap, xsig, "CMS signature"))
            signer_out = os.path.join(tmp, "cms-signer.pem")
            rc, out, err = openssl("cms", "-verify", "-inform", "DER", "-in", cms, "-binary",
                                   "-content", cksum, "-CAfile", trust_root, "-purpose", "any",
                                   "-ignore_critical", "-certfile", inter,
                                   "-signer", signer_out, "-out", os.devnull)
            if rc != 0:
                raise Refused("the CMS signature does not verify against the trust root: "
                              + err.strip().replace("\n", " | "))
            with open(signer_out, "rb") as fh:
                cms_signer = fh.read()
            if subject_and_fingerprint(cms_signer)[1] != subject_and_fingerprint(chain[signer_index])[1]:
                raise Refused("the CMS signature's signer is not the RSA signature's certificate")
            cms_note = "CMS signature verified"

        subject, fpr = subject_and_fingerprint(chain[signer_index])
    return {"subject": subject, "sha256": fpr, "rsa": verified_form, "cms": cms_note,
            "files": files, "checksum": alg}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("package")
    ap.add_argument("--trust-root", help="PEM root certificate the signer must chain to")
    ap.add_argument("--print-signer", action="store_true",
                    help="print the signer's subject and SHA-256 fingerprint; verify nothing")
    args = ap.parse_args(argv)
    try:
        if args.print_signer:
            toc, _, _, _ = read_package(args.package)
            sig = toc.find("toc/signature")
            if sig is None:
                print(f"{args.package}: not signed", file=sys.stderr)
                return 3
            for der in certificates(sig):
                subject, fpr = subject_and_fingerprint(pem_of(der))
                print(f"{fpr} {subject}")
            return 0
        if not args.trust_root:
            ap.error("--trust-root is required (or --print-signer)")
        if not os.path.isfile(args.trust_root):
            raise Refused(f"--trust-root {args.trust_root} does not exist")
        r = verify(args.package, args.trust_root)
    except Refused as exc:
        print(f"verify-xar-signature: REFUSED {args.package}: {exc}", file=sys.stderr)
        return 1
    print(f"verify-xar-signature: OK {args.package}")
    print(f"  signer:   {r['subject']}")
    print(f"  sha256:   {r['sha256']}")
    print(f"  RSA:      {r['rsa']}")
    print(f"  CMS:      {r['cms']}")
    print(f"  checksum: {r['checksum']} over the table of contents; {r['files']} file checksum(s) verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
