## ReproOS-Generations-And-Foreign-Packages A2 — repro-binary-cache CLI.
##
## Drives the HTTP server defined in
## ``libs/repro_binary_cache_server/src/repro_binary_cache_server/server.nim``.
## On startup it:
##
##   * Materialises the on-disk layout under ``--root``
##     (``/var/lib/repro-binary-cache`` on the deployed repro-cache distro).
##   * Loads or generates the persistent ECDSA-P256 producer keypair
##     at ``<root>/trust/server-ecdsa-p256.{key,cert}``.
##   * Writes the ``cache-info.bin`` record under
##     ``<root>/index/`` so a client can poll the advertised
##     ``StoreDir`` + priority + mass-query flag + producer pubkey
##     without hitting the network.
##   * Binds the REST handlers on ``--listen`` (defaults to
##     ``0.0.0.0:7878``).
##
## Idempotent: rerunning against a populated ``--root`` reloads the
## existing producer key + manifests; no state is reset.

import std/[asyncdispatch, os, parseopt, sets, strutils]

import repro_binary_cache_server
import repro_local_store

const
  Usage = """
repro-binary-cache — ReproOS-Generations-And-Foreign-Packages A2 daemon.

Usage:
  repro-binary-cache [--root=PATH] [--listen=HOST:PORT] [--store-dir=PATH]

Options:
  --root=PATH         On-disk layout root. Default: $REPRO_BINARY_CACHE_ROOT
                      or /var/lib/repro-binary-cache.
  --listen=HOST:PORT  Bind address. Default: 0.0.0.0:7878.
  --store-dir=PATH    Value advertised in GET /cache-info as StoreDir.
                      Default: <root>/store.
  --tls-cert=PATH     PEM certificate for HTTPS. When BOTH --tls-cert and
                      --tls-key are set (or REPRO_BINARY_CACHE_TLS_CERT /
                      _TLS_KEY), the server serves over TLS; otherwise it
                      serves plain HTTP (unchanged). Requires -d:ssl.
  --tls-key=PATH      PEM private key for the HTTPS cert.
  --allowed-signers=PATH
                      Publish-authorization allowlist: one 130-char hex
                      ECDSA-P256 producer pubkey per non-blank/#-line.
                      When set (or via REPRO_BINARY_CACHE_ALLOWED_SIGNERS),
                      POST /publish is ENFORCED — a manifest whose producer
                      pubkey is not listed is rejected 403 with NOTHING
                      stored. Unset ⇒ permissive (v1 default). The server's
                      own producer key is always allowed.
  --print-pubkey      Print the producer ECDSA-P256 public key hex on
                      stdout AND keep running. Useful for trust-anchor
                      provisioning + integration tests.
  --once              Bind, print the producer key, then exit without
                      entering the accept loop. Test-only.
  -h, --help          Show this help.

The server runs forever once bound. Logs go to stderr.
"""

type
  CliOpts = object
    root: string
    listen: string
    storeDir: string
    tlsCert: string
    tlsKey: string
    allowedSigners: string
    printPubkey: bool
    once: bool
    showHelp: bool

proc parseCli(): CliOpts =
  result.listen = DefaultListenAddr
  result.root = getEnv("REPRO_BINARY_CACHE_ROOT",
                       "/var/lib/repro-binary-cache")
  result.tlsCert = getEnv("REPRO_BINARY_CACHE_TLS_CERT", "")
  result.tlsKey = getEnv("REPRO_BINARY_CACHE_TLS_KEY", "")
  result.allowedSigners = getEnv("REPRO_BINARY_CACHE_ALLOWED_SIGNERS", "")
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii()
      of "h", "help":
        result.showHelp = true
      of "root":
        result.root = p.val
      of "listen":
        result.listen = p.val
      of "store-dir", "storedir":
        result.storeDir = p.val
      of "tls-cert", "tlscert":
        result.tlsCert = p.val
      of "tls-key", "tlskey":
        result.tlsKey = p.val
      of "allowed-signers", "allowedsigners":
        result.allowedSigners = p.val
      of "print-pubkey", "printpubkey":
        result.printPubkey = true
      of "once":
        result.once = true
      else:
        stderr.writeLine("unknown option: --" & p.key)
        quit(2)
    of cmdArgument:
      stderr.writeLine("unexpected positional argument: " & p.key)
      quit(2)

proc hex65(pub: PublicKeyBytes): string =
  const HexChars = "0123456789abcdef"
  result = newStringOfCap(130)
  for b in pub:
    result.add(HexChars[int(b shr 4) and 0x0f])
    result.add(HexChars[int(b) and 0x0f])

proc main() {.async.} =
  let opts = parseCli()
  if opts.showHelp:
    echo Usage
    quit(0)
  if opts.root.len == 0:
    stderr.writeLine("--root or REPRO_BINARY_CACHE_ROOT is required")
    quit(2)
  # A4 P4 / Debt 2 — env-driven cap config. 0 disables the
  # corresponding cap; the operator handbook documents the per-host
  # tuning recipe. The pin-list lives at
  # ``recipes/cache/pinned-entries.txt`` in production; the operator
  # can override the path via REPRO_BINARY_CACHE_PIN_LIST.
  let softCap = block:
    let raw = getEnv("REPRO_BINARY_CACHE_SOFT_CAP_BYTES")
    if raw.len == 0: DefaultSoftCapBytes
    else:
      try: parseBiggestInt(raw).int64
      except ValueError:
        stderr.writeLine("WARN: invalid REPRO_BINARY_CACHE_SOFT_CAP_BYTES=" & raw &
                         "; falling back to default")
        DefaultSoftCapBytes
  let hardCap = block:
    let raw = getEnv("REPRO_BINARY_CACHE_HARD_CAP_BYTES")
    if raw.len == 0: DefaultHardCapBytes
    else:
      try: parseBiggestInt(raw).int64
      except ValueError:
        stderr.writeLine("WARN: invalid REPRO_BINARY_CACHE_HARD_CAP_BYTES=" & raw &
                         "; falling back to default")
        DefaultHardCapBytes
  let pinListPath = getEnv("REPRO_BINARY_CACHE_PIN_LIST", "")
  let state = openBinaryCacheServer(opts.root, opts.storeDir,
                                    softCapBytes = softCap,
                                    hardCapBytes = hardCap,
                                    pinListPath = pinListPath)
  defer: close(state)
  # Windows-Runner-Binary-Cache-Deploy M6 — publish-authorization allowlist.
  # Load from --allowed-signers (or REPRO_BINARY_CACHE_ALLOWED_SIGNERS)
  # when set; the server's own key is always allowed. Absent ⇒ permissive.
  if opts.allowedSigners.len > 0:
    if not fileExists(opts.allowedSigners):
      stderr.writeLine("--allowed-signers file not found: " & opts.allowedSigners)
      quit(2)
    loadAllowedSignersFile(state, opts.allowedSigners)
    stderr.writeLine("repro-binary-cache publish authz ENFORCED (" &
      $state.allowedSigners.publicKeys.len & " allowed signer(s))")
  if opts.printPubkey or opts.once:
    stdout.writeLine(hex65(state.producerKeypair.publicKey))
    stdout.flushFile()
  if opts.once:
    return
  let srv = newBinaryCacheHttpServer(state)
  # Windows-Runner-Binary-Cache-Deploy M6 — opt-in HTTPS.
  if opts.tlsCert.len > 0 or opts.tlsKey.len > 0:
    if opts.tlsCert.len == 0 or opts.tlsKey.len == 0:
      stderr.writeLine("--tls-cert and --tls-key must be set together")
      quit(2)
    srv.tlsCertFile = opts.tlsCert
    srv.tlsKeyFile = opts.tlsKey
  await srv.start(opts.listen)
  let scheme = if srv.tlsEnabled(): "https" else: "http"
  stderr.writeLine("repro-binary-cache listening on " & opts.listen &
                   " (" & scheme & ")")
  stderr.writeLine("repro-binary-cache root          = " & opts.root)
  stderr.writeLine("repro-binary-cache storeDir adv  = " & state.info.storeDir)
  stderr.flushFile()
  while srv.running:
    await sleepAsync(1000)

when isMainModule:
  waitFor main()
