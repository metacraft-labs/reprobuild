## `repro store copy` — the command-line face of
## `repro_local_store/store_copy`.
##
## This module only parses arguments, resolves the source store root exactly
## as the other `repro store` subcommands resolve it, and prints the report.
## All copy behaviour lives in the library.
##
## One decision belongs to the caller and is passed in as a hook: whether
## the destination is a store that a host lock serialises (the add-on's
## system store), and taking that lock. The main CLI module owns it, and
## that module imports this one.

import std/[json, os, strutils]
import repro_local_store/store
when not defined(windows):
  import repro_local_store/store_copy

type
  StoreCopyCliHooks* = object
    withDestinationLock*: proc (destinationRoot: string;
                                body: proc (): int): int
      ## Runs `body` holding whatever lock writers of `destinationRoot`
      ## must hold, and returns its result.

const StoreCopyUsage* = """usage:
  repro store copy [PREFIX...] [--root-id=ID]... --to=STORE-ROOT
                   [--store-root=PATH] [--json]
PREFIX is a prefix of the source store, as an absolute path or as
prefixes/<pkg>/<dir>; a path inside a prefix names that prefix.
--root-id copies every prefix a registered source root holds."""

when defined(windows):
  proc runStoreCopyCommand*(args: seq[string]; hooks: StoreCopyCliHooks): int =
    stderr.writeLine("repro store copy: not supported on Windows")
    1
else:
  proc reportJson(r: StoreCopyReport): JsonNode =
    %*{
      "sourceStoreRoot": r.sourceRoot,
      "destinationStoreRoot": r.destinationRoot,
      "rootId": r.rootId,
      "closure": r.closure.len,
      "copied": r.copied,
      "alreadyPresent": r.alreadyPresent,
      "unverified": r.unverified,
      "external": r.external,
      "copiedBytes": r.copiedBytes
    }

  proc printReport(r: StoreCopyReport) =
    echo "repro store copy: " & r.sourceRoot & " -> " & r.destinationRoot
    echo "closure:         " & $r.closure.len & " prefix(es)"
    echo "copied:          " & $r.copied.len & " (" & $r.copiedBytes & " bytes)"
    for p in r.copied: echo "  + " & p
    echo "already present: " & $r.alreadyPresent.len
    for p in r.unverified:
      echo "unverified (receipt records no content digest): " & p
    for p in r.external:
      echo "external (import metadata only; payload not copied): " & p
    echo "held by root:    " & r.rootId

  proc runStoreCopyCommand*(args: seq[string]; hooks: StoreCopyCliHooks): int =
    ## `args[0]` is `copy`.
    var req: StoreCopyRequest
    var storeRootFlag = ""
    var emitJson = false
    for raw in (if args.len > 1: args[1 .. ^1] else: @[]):
      if raw.startsWith("--store-root="):
        storeRootFlag = raw.split('=', 1)[1]
      elif raw.startsWith("--to="):
        req.destinationRoot = raw.split('=', 1)[1]
      elif raw.startsWith("--root-id="):
        req.rootIds.add(raw.split('=', 1)[1])
      elif raw == "--json":
        emitJson = true
      elif raw in ["-h", "--help"]:
        echo StoreCopyUsage
        return 0
      elif raw.startsWith("--"):
        stderr.writeLine("repro store copy: unknown flag: " & raw)
        return 2
      else:
        req.prefixes.add(raw)
    if req.destinationRoot.len == 0:
      stderr.writeLine("repro store copy: --to=STORE-ROOT is required\n" &
        StoreCopyUsage)
      return 2
    if req.prefixes.len == 0 and req.rootIds.len == 0:
      stderr.writeLine("repro store copy: name at least one PREFIX or " &
        "--root-id\n" & StoreCopyUsage)
      return 2
    # Resolving the roots and taking the destination's lock can fail too;
    # every failure is reported as one `error:` line and exit 1, never a
    # traceback.
    try:
      req.sourceRoot = resolveStoreRoot(storeRootFlag)
      req.destinationRoot = absolutePath(req.destinationRoot)
      hooks.withDestinationLock(req.destinationRoot, proc (): int =
        let report = copyClosure(req)
        if emitJson: echo pretty(reportJson(report))
        else: printReport(report)
        0)
    except CatchableError:
      stderr.writeLine("repro store copy: error: " & getCurrentExceptionMsg())
      1
