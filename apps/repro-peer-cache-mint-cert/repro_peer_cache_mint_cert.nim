## Peer-Cache-BearSSL M4 mint-cert CLI.
##
## Operator ergonomics tool for the BearSSL TLS path. Three modes:
##
##   * `--self-signed --out=<dir>` — generates an ECDSA-P256 keypair
##     and a self-signed cert; writes `<dir>/peer.crt` + `<dir>/peer.key`;
##     prints the derived peer-id hex to stdout.
##
##   * `--import-ca --out=<dir>` — generates an ECDSA-P256 keypair and
##     a mini-CA cert (`BasicConstraints cA:TRUE`, `KeyUsage keyCertSign`);
##     writes `<dir>/ca.crt` + `<dir>/ca.key`.
##
##   * `--ca-key=<path> --ca-cert=<path> --peer-id=<hex> --out=<dir>` —
##     generates an ECDSA-P256 peer keypair and a peer cert signed by
##     the provided CA; writes `<dir>/peer.crt` + `<dir>/peer.key`. The
##     `--peer-id` argument is the cert's subject CN; pass the derived
##     peer-id hex (typically the output of a prior `--self-signed` run).
##
## See `Peer-Cache-BearSSL.milestones.org` §M4.
##
## Library entry point: `mintCertMain(argv: openArray[string]): int`.
## The `when isMainModule` block at the bottom forwards `paramStr(1..)`.

import std/[os, parseopt, strutils]

import repro_peer_cache

const
  UsageBanner = """repro-peer-cache-mint-cert: mint TLS certs for the peer-cache.

Modes:
  --self-signed --out=<dir>
      Generate ECDSA-P256 keypair + self-signed cert.
      Writes <dir>/peer.crt and <dir>/peer.key.
      Prints derived peer-id hex to stdout.

  --import-ca --out=<dir>
      Generate ECDSA-P256 keypair + mini-CA cert.
      Writes <dir>/ca.crt and <dir>/ca.key.

  --ca-key=<path> --ca-cert=<path> --peer-id=<hex> --out=<dir>
      Generate peer keypair + peer cert signed by the CA.
      Writes <dir>/peer.crt and <dir>/peer.key.

Common options:
  --validity-days=<n>   Cert validity window in days (default 365).
"""

type
  MintCertMode = enum
    mcmNone, mcmSelfSigned, mcmImportCa, mcmCaSigned

  MintCertOptions = object
    mode: MintCertMode
    outDir: string
    caCertPath: string
    caKeyPath: string
    peerId: string
    validityDays: int

proc emitUsage(): int =
  stderr.write(UsageBanner)
  result = 2

proc parseOpts(argv: openArray[string]): tuple[ok: bool; opts: MintCertOptions] =
  var opts = MintCertOptions(mode: mcmNone, validityDays: 365)
  var p = initOptParser(@argv)
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "self-signed":
        if opts.mode != mcmNone:
          stderr.writeLine("repro-peer-cache-mint-cert: cannot combine modes")
          return (false, opts)
        opts.mode = mcmSelfSigned
      of "import-ca":
        if opts.mode != mcmNone:
          stderr.writeLine("repro-peer-cache-mint-cert: cannot combine modes")
          return (false, opts)
        opts.mode = mcmImportCa
      of "out":
        opts.outDir = p.val
      of "ca-cert":
        opts.caCertPath = p.val
        if opts.mode == mcmNone: opts.mode = mcmCaSigned
      of "ca-key":
        opts.caKeyPath = p.val
        if opts.mode == mcmNone: opts.mode = mcmCaSigned
      of "peer-id":
        opts.peerId = p.val
        if opts.mode == mcmNone: opts.mode = mcmCaSigned
      of "validity-days":
        try:
          opts.validityDays = parseInt(p.val)
        except ValueError:
          stderr.writeLine("repro-peer-cache-mint-cert: invalid --validity-days: " & p.val)
          return (false, opts)
      of "help", "h":
        stderr.write(UsageBanner)
        return (false, opts)
      else:
        stderr.writeLine("repro-peer-cache-mint-cert: unknown option: --" & p.key)
        return (false, opts)
    of cmdArgument:
      stderr.writeLine("repro-peer-cache-mint-cert: unexpected positional argument: " & p.key)
      return (false, opts)
  return (true, opts)

proc runSelfSigned(opts: MintCertOptions): int =
  if opts.outDir.len == 0:
    stderr.writeLine("repro-peer-cache-mint-cert: --self-signed requires --out=<dir>")
    return 2
  createDir(opts.outDir)
  let kp = generateKeypair()
  let peerId = derivePeerIdFromPublicKey(kp.publicKey)
  let cnHex = $peerId
  let cert = generateSelfSignedCert(kp, subjectCn = cnHex,
                                    validityDays = opts.validityDays)
  writeCertAndKey(cert, opts.outDir / "peer.crt", opts.outDir / "peer.key")
  echo cnHex
  result = 0

proc runImportCa(opts: MintCertOptions): int =
  if opts.outDir.len == 0:
    stderr.writeLine("repro-peer-cache-mint-cert: --import-ca requires --out=<dir>")
    return 2
  createDir(opts.outDir)
  let kp = generateKeypair()
  let caPeerId = derivePeerIdFromPublicKey(kp.publicKey)
  let cnHex = "ca-" & $caPeerId
  let cert = generateCaCert(kp, subjectCn = cnHex,
                            validityDays = opts.validityDays)
  writeCertAndKey(cert, opts.outDir / "ca.crt", opts.outDir / "ca.key")
  echo cnHex
  result = 0

proc runCaSigned(opts: MintCertOptions): int =
  if opts.outDir.len == 0:
    stderr.writeLine("repro-peer-cache-mint-cert: CA-signed mode requires --out=<dir>")
    return 2
  if opts.caCertPath.len == 0 or opts.caKeyPath.len == 0:
    stderr.writeLine("repro-peer-cache-mint-cert: CA-signed mode requires --ca-cert and --ca-key")
    return 2
  createDir(opts.outDir)
  let ca = loadCertAndKey(opts.caCertPath, opts.caKeyPath)
  let peerKp = generateKeypair()
  let derivedPeerId = derivePeerIdFromPublicKey(peerKp.publicKey)
  let subjectCn =
    if opts.peerId.len > 0: opts.peerId
    else: $derivedPeerId
  let peerCert = generateCaSignedCert(
    peerKeypair = peerKp,
    subjectCn = subjectCn,
    caCertDer = ca.certDer,
    caKeypair = ca.keypair,
    validityDays = opts.validityDays)
  writeCertAndKey(peerCert, opts.outDir / "peer.crt",
                  opts.outDir / "peer.key")
  echo subjectCn
  result = 0

proc mintCertMain*(argv: openArray[string]): int =
  ## Library entry point: invoke the CLI logic in-process. Returns
  ## the exit code the binary would have used. The verification tests
  ## call this directly rather than spawning the binary so they don't
  ## depend on a built artifact.
  let parsed = parseOpts(argv)
  if not parsed.ok:
    return 2
  case parsed.opts.mode
  of mcmNone:
    return emitUsage()
  of mcmSelfSigned:
    return runSelfSigned(parsed.opts)
  of mcmImportCa:
    return runImportCa(parsed.opts)
  of mcmCaSigned:
    return runCaSigned(parsed.opts)

when isMainModule:
  var argv: seq[string] = @[]
  for i in 1 .. paramCount():
    argv.add(paramStr(i))
  quit(mintCertMain(argv))
