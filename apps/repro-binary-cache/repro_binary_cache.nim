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

import std/[asyncdispatch, os, parseopt, strutils]

import repro_binary_cache_server

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
    printPubkey: bool
    once: bool
    showHelp: bool

proc parseCli(): CliOpts =
  result.listen = DefaultListenAddr
  result.root = getEnv("REPRO_BINARY_CACHE_ROOT",
                       "/var/lib/repro-binary-cache")
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
  let state = openBinaryCacheServer(opts.root, opts.storeDir)
  defer: close(state)
  if opts.printPubkey or opts.once:
    stdout.writeLine(hex65(state.producerKeypair.publicKey))
    stdout.flushFile()
  if opts.once:
    return
  let srv = newBinaryCacheHttpServer(state)
  await srv.start(opts.listen)
  stderr.writeLine("repro-binary-cache listening on " & opts.listen)
  stderr.writeLine("repro-binary-cache root          = " & opts.root)
  stderr.writeLine("repro-binary-cache storeDir adv  = " & state.info.storeDir)
  stderr.flushFile()
  while srv.running:
    await sleepAsync(1000)

when isMainModule:
  waitFor main()
