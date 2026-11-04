## `repro store closure | export | import` — the command-line face of
## `repro_local_store/store_bundle` (see `docs/store-bundles.md`).
##
## This module only parses arguments, resolves roots exactly as `repro build`
## resolves them, captures frozen dev-env activations and prints reports. All
## bundle behaviour lives in the library.
##
## Two helpers belong to the main CLI module and are passed in as hooks
## instead of being imported, because that module imports this one:
## resolving the action-cache root (the same precedence `repro build` uses)
## and writing a dev-env allow file (the same file `repro allow` writes).

import std/[json, os, osproc, streams, strtabs, strutils]
import blake3
import repro_core/ambient_execution
import repro_local_store/store
when not defined(windows):
  import repro_local_store/store_bundle

type
  StoreBundleCliHooks* = object
    resolveActionCacheRoot*: proc (explicit: string): string
    allowProject*: proc (projectRoot: string): int

const StoreBundleUsage* = """usage:
  repro store closure --root=DIR... [--json]
  repro store export  --root=DIR... --out=DIR [--freeze-dev-env=PROJECT]...
                      [--part-size=SIZE] [--zstd-level=N] [--zstd-threads=N]
  repro store import  DIR [--root=DIR]... [--allow-dev-env] [--force]
common: [--store-root=PATH] [--action-cache-root=PATH]
See docs/store-bundles.md."""

when defined(windows):
  proc runStoreBundleCommand*(args: seq[string];
                              hooks: StoreBundleCliHooks): int =
    ## Bundles need POSIX nanosecond timestamps (docs/store-bundles.md).
    stderr.writeLine("repro store " & (if args.len > 0: args[0] else: "") &
      ": store bundles are not supported on Windows")
    1
else:
  proc parseSize(text: string; value: var int64): bool =
    ## `64M`, `1G`, `65536`. Binary units.
    if text.len == 0: return false
    var digits = text
    var mult = 1'i64
    case text[^1]
    of 'k', 'K': mult = 1024
    of 'm', 'M': mult = 1024 * 1024
    of 'g', 'G': mult = 1024 * 1024 * 1024
    else: discard
    if mult != 1: digits = text[0 ..< ^1]
    try:
      value = parseBiggestInt(digits) * mult
      value > 0
    except ValueError:
      false

  proc frozenScriptPath*(storeRoot, projectRoot: string): string =
    ## `<store>/frozen-dev-env/<blake3(projectRoot)[0..31]>/activate.bash`.
    storeRoot / FrozenDevEnvDirName /
      blake3.digest(projectRoot).toHex()[0 ..< 32] / "activate.bash"

  proc shellQuote(value: string): string =
    "'" & value.replace("'", "'\\''") & "'"

  proc freezeDevEnv(projectRoot, storeRoot: string): FrozenDevEnv =
    ## §6: run the ordinary hook export once, now, and keep its output. The
    ## export runs with auto-allow because the person producing the bundle is
    ## the one consenting here; the importing side consents separately
    ## (`--allow-dev-env`).
    let root = normalizedPath(absolutePath(projectRoot))
    let self = getAppFilename()
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      env[key] = value
    env["REPRO_DEV_ENV_AUTO_ALLOW"] = "1"
    # A frozen activation must not be a no-op because the exporting shell
    # happens to have the project active already.
    for marker in ["__REPRO_APPLIED", "__REPRO_PROJECT_ROOT",
        "__REPRO_ACTIVE_MANIFEST", "__REPRO_WARNED"]:
      if env.hasKey(marker): env.del(marker)
    let p = uncontrolledStartProcess(self, workingDir = root,
      args = ["dev-env", "export", "bash", "--project-root", root],
      env = env, options = {})
    let script = p.outputStream.readAll()
    let errText = p.errorStream.readAll()
    let code = p.waitForExit()
    p.close()
    if code != 0:
      raise newException(StoreBundleError, "dev-env export for " & root &
        " failed (exit " & $code & "): " & errText.strip())
    if "__REPRO_APPLIED" notin script:
      raise newException(StoreBundleError, "dev-env export for " & root &
        " produced no activation (is it a repro project?): " &
        script.strip() & " " & errText.strip())
    let path = frozenScriptPath(storeRoot, root)
    createDir(path.parentDir)
    var text = "# Frozen repro dev-env activation for " & root & ".\n" &
      "# Produced by `repro store export --freeze-dev-env`; sourcing it runs\n" &
      "# no repro process. See docs/store-bundles.md section 6.\n" &
      "if [ ! -d " & shellQuote(root) & " ]; then\n" &
      "  echo " & shellQuote("repro: frozen dev-env project " & root &
        " does not exist") & " >&2\n" &
      "  return 1 2>/dev/null || exit 1\n" &
      "fi\n" & script
    if not text.endsWith("\n"): text.add("\n")
    # The shell hook calls repro only when this differs from the project it
    # finds, so the frozen activation stays in force without an engine run.
    text.add("export __REPRO_PROJECT_ROOT=" & shellQuote(root) & "\n")
    writeFile(path, text)
    FrozenDevEnv(projectRoot: root, scriptPath: path)

  proc closureJson(c: BundleClosure): JsonNode =
    var skipped = newJArray()
    for s in c.skippedRecords:
      skipped.add(%*{"edge": s.edgeDir, "record": s.strongHex,
        "reason": s.reason})
    %*{
      "roots": {"storeRoot": c.roots.storeRoot,
        "actionCacheRoot": c.roots.actionCacheRoot,
        "workspaceRoots": %c.roots.workspaceRoots},
      "edges": %c.edges,
      "records": c.records.len,
      "prefixes": %c.prefixes,
      "entries": c.entries.len,
      "unpackedBytes": c.unpackedBytes,
      "restamps": c.restamps.len,
      "skippedRecords": skipped
    }

  proc printClosureText(c: BundleClosure) =
    echo "store root:        " & c.roots.storeRoot
    echo "action-cache root: " & c.roots.actionCacheRoot
    for r in c.roots.workspaceRoots:
      echo "workspace root:    " & r
    echo "edges:             " & $c.edges.len & " (" & $c.records.len &
      " re-witnessable records)"
    echo "store prefixes:    " & $c.prefixes.len
    for p in c.prefixes:
      echo "  " & p
    echo "entries:           " & $c.entries.len & " (" & $c.unpackedBytes &
      " bytes)"
    echo "restamped inputs:  " & $c.restamps.len
    for s in c.skippedRecords:
      echo "skipped record " & s.strongHex[0 ..< 16] & " in " &
        s.edgeDir.extractFilename & ": " & s.reason

  proc runStoreBundleCommand*(args: seq[string];
                              hooks: StoreBundleCliHooks): int =
    ## `args[0]` is the subcommand.
    if args.len == 0:
      echo StoreBundleUsage
      return 2
    let sub = args[0]
    var storeRootFlag, acRootFlag, outDir = ""
    var roots, freeze, positionals: seq[string]
    var emitJson, allowDevEnv, force = false
    var exportOpts = defaultExportOptions("")
    for raw in args[1 .. ^1]:
      if raw.startsWith("--store-root="):
        storeRootFlag = raw.split('=', 1)[1]
      elif raw.startsWith("--action-cache-root="):
        acRootFlag = raw.split('=', 1)[1]
      elif raw.startsWith("--root="):
        roots.add(raw.split('=', 1)[1])
      elif raw.startsWith("--out="):
        outDir = raw.split('=', 1)[1]
      elif raw.startsWith("--freeze-dev-env="):
        freeze.add(raw.split('=', 1)[1])
      elif raw.startsWith("--part-size="):
        if not parseSize(raw.split('=', 1)[1], exportOpts.partSize):
          stderr.writeLine("repro store " & sub & ": bad --part-size: " & raw)
          return 2
      elif raw.startsWith("--zstd-level="):
        try: exportOpts.zstdLevel = parseInt(raw.split('=', 1)[1])
        except ValueError:
          stderr.writeLine("repro store " & sub & ": bad --zstd-level: " & raw)
          return 2
      elif raw.startsWith("--zstd-threads="):
        try: exportOpts.zstdThreads = parseInt(raw.split('=', 1)[1])
        except ValueError:
          stderr.writeLine("repro store " & sub & ": bad --zstd-threads: " & raw)
          return 2
      elif raw == "--json": emitJson = true
      elif raw == "--allow-dev-env": allowDevEnv = true
      elif raw == "--force": force = true
      elif raw in ["-h", "--help"]:
        echo StoreBundleUsage
        return 0
      elif raw.startsWith("--"):
        stderr.writeLine("repro store " & sub & ": unknown flag: " & raw)
        return 2
      else:
        positionals.add(raw)

    let local = BundleRoots(
      storeRoot: resolveStoreRoot(storeRootFlag),
      actionCacheRoot: hooks.resolveActionCacheRoot(acRootFlag),
      workspaceRoots: roots)
    try:
      case sub
      of "closure", "export":
        if positionals.len > 0:
          stderr.writeLine("repro store " & sub & ": unexpected argument: " &
            positionals[0])
          return 2
        if roots.len == 0:
          stderr.writeLine("repro store " & sub & ": at least one --root=DIR " &
            "is required\n" & StoreBundleUsage)
          return 2
        if sub == "export" and outDir.len == 0:
          stderr.writeLine("repro store export: --out=DIR is required")
          return 2
        var devEnvs: seq[FrozenDevEnv]
        if sub == "export":
          for project in freeze:
            devEnvs.add(freezeDevEnv(project, local.storeRoot))
        else:
          # `closure` writes nothing: it reports scripts an earlier export
          # froze, if they are still there.
          for project in freeze:
            let root = normalizedPath(absolutePath(project))
            let path = frozenScriptPath(local.storeRoot, root)
            if fileExists(path):
              devEnvs.add(FrozenDevEnv(projectRoot: root, scriptPath: path))
        let closure = computeClosure(local, devEnvs)
        if sub == "closure":
          if emitJson: echo pretty(closureJson(closure))
          else: printClosureText(closure)
          return 0
        exportOpts.outDir = absolutePath(outDir)
        when declared(ReprobuildSourceRevision):
          exportOpts.reproRevision = ReprobuildSourceRevision
        let report = exportBundle(closure, exportOpts)
        if emitJson:
          echo readFile(report.manifestPath)
        else:
          echo "bundle " & report.bundleId & ": " & $report.entryCount &
            " entries, " & $report.unpackedBytes & " bytes unpacked, " &
            $report.compressedBytes & " bytes in " & $report.parts.len &
            " part(s)"
          echo "manifest: " & report.manifestPath
          for env in closure.devEnvs:
            echo "frozen dev-env: " & env.projectRoot & " -> " & env.scriptPath
        return 0
      of "import":
        if positionals.len != 1:
          stderr.writeLine("repro store import: exactly one bundle directory " &
            "is required\n" & StoreBundleUsage)
          return 2
        let report = importBundle(ImportOptions(bundleDir: positionals[0],
          force: force), local)
        if allowDevEnv:
          for env in report.devEnvs:
            if hooks.allowProject(env.projectRoot) != 0:
              return 1
        if emitJson:
          var envs = newJArray()
          var phases = newJObject()
          for (phase, seconds) in report.phaseSeconds:
            phases[phase] = %seconds
          for env in report.devEnvs:
            envs.add(%*{"projectRoot": env.projectRoot,
              "script": env.scriptPath})
          echo pretty(%*{
            "bundleId": report.bundleId,
            "skippedExtraction": report.skippedExtraction,
            "excludedPrefixes": report.excludedPrefixes.len,
            "verifiedEntries": report.verifiedEntries,
            "reinsertedPrefixes": report.reinsertedPrefixes,
            "quarantinedPrefixes": %report.quarantinedPrefixes,
            "rewitnessedRecords": report.rewitnessedRecords,
            "restamped": report.restamped,
            "restampMismatches": report.restampMismatches,
            "frozenDevEnvs": envs,
            "phaseSeconds": phases})
        else:
          echo "bundle " & report.bundleId &
            (if report.skippedExtraction: ": already imported, verified"
             else: ": imported")
          echo "  verified entries:     " & $report.verifiedEntries
          echo "  prefixes reinserted:  " & $report.reinsertedPrefixes &
            " (" & $report.excludedPrefixes.len & " already present)"
          echo "  records re-witnessed: " & $report.rewitnessedRecords
          echo "  inputs restamped:     " & $report.restamped &
            (if report.restampMismatches > 0:
               " (" & $report.restampMismatches & " differ and were left alone)"
             else: "")
          for q in report.quarantinedPrefixes:
            echo "  quarantined: " & q
          for env in report.devEnvs:
            echo "  frozen dev-env: source " & env.scriptPath
        return if report.quarantinedPrefixes.len > 0: 1 else: 0
      else:
        stderr.writeLine("repro store: unknown bundle subcommand: " & sub)
        return 2
    except StoreBundleError, StoreError, OSError, IOError:
      stderr.writeLine("repro store " & sub & ": error: " &
        getCurrentExceptionMsg())
      return 1
