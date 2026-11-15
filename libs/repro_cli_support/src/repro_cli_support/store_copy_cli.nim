## `repro store copy` — the command-line face of
## `repro_local_store/store_copy`.
##
## This module only takes the parsed arguments, resolves the source store
## root exactly as the other `repro store` subcommands resolve it, and
## prints the report.
## All copy behaviour lives in the library.
##
## One decision belongs to the caller and is passed in as a hook: whether
## the destination is a store that a host lock serialises (the add-on's
## system store), and taking that lock. The main CLI module owns it, and
## that module imports this one.

import std/[json, os]
import repro_local_store/store
when not defined(windows):
  import repro_local_store/store_copy

type
  StoreCopyCliHooks* = object
    withDestinationLock*: proc (destinationRoot: string;
                                body: proc (): int): int
      ## Runs `body` holding whatever lock writers of `destinationRoot`
      ## must hold, and returns its result.

const StoreCopyHelpHint = "run `repro store copy --help` for its usage"

when defined(windows):
  proc runStoreCopyCommand*(prefixes, rootIds: seq[string];
                            destinationRoot, storeRootFlag: string;
                            emitJson: bool; hooks: StoreCopyCliHooks): int =
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

  proc runStoreCopyCommand*(prefixes, rootIds: seq[string];
                            destinationRoot, storeRootFlag: string;
                            emitJson: bool; hooks: StoreCopyCliHooks): int =
    ## `repro store copy [PREFIX...] [--root-id=ID]... --to=STORE-ROOT
    ## [--store-root=PATH] [--json]`, its command line parsed from repro's
    ## description (`repro_cli_support/cli_description`).
    var req = StoreCopyRequest(prefixes: prefixes, rootIds: rootIds,
      destinationRoot: destinationRoot)
    if req.destinationRoot.len == 0:
      stderr.writeLine("repro store copy: --to=STORE-ROOT is required; " &
        StoreCopyHelpHint)
      return 2
    if req.prefixes.len == 0 and req.rootIds.len == 0:
      stderr.writeLine("repro store copy: name at least one PREFIX or " &
        "--root-id; " & StoreCopyHelpHint)
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
