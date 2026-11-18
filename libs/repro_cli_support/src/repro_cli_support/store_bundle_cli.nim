## `repro store closure | export | import` — the command-line face of
## `repro_local_store/store_bundle` (see `docs/store-bundles.md`).
##
## This module only takes the parsed arguments (repro's command line is
## parsed from its description, `repro_cli_support/cli_description`),
## resolves roots exactly as `repro build` resolves them, captures frozen
## dev-env activations and prints reports. All bundle behaviour lives in the
## library.
##
## Two helpers belong to the main CLI module and are passed in as hooks
## instead of being imported, because that module imports this one:
## resolving the action-cache root (the same precedence `repro build` uses)
## and writing a dev-env allow file (the same file `repro allow` writes).

from repro_core/process_streams import drainStream
import std/[json, options, os, osproc, streams, strtabs, strutils]
import repro_core/ambient_execution
import repro_local_store/store
when not defined(windows):
  import repro_local_store/store_bundle
  import repro_bundle/select
  import ./bundle_nim_pins

type
  StoreBundleCliHooks* = object
    resolveActionCacheRoot*: proc (explicit: string): string
    allowProject*: proc (projectRoot: string): int
    workspaceRootFor*: proc (startPath: string): string
      ## The workspace enclosing a directory, or "" (for `--selection`).

  StoreBundleArgs* = object
    ## What `repro store closure|export|import` was given; each subcommand
    ## reads the fields its flags fill.
    storeRoot*: string            ## `--store-root`
    actionCacheRoot*: string      ## `--action-cache-root`
    roots*: seq[string]           ## `--root`, repeated
    freezeDevEnv*: seq[string]    ## `--freeze-dev-env`, repeated
    outDir*: string               ## `--out`
    partSize*: string             ## `--part-size`
    zstdLevel*: Option[int]       ## `--zstd-level`
    zstdThreads*: Option[int]     ## `--zstd-threads`
    emitJson*: bool               ## `--json`
    allowDevEnv*: bool            ## `--allow-dev-env`
    force*: bool                  ## `--force`
    bundleDir*: string            ## `import`'s bundle directory
    selection*: string            ## `--selection`
    workspaceRoot*: string        ## `--workspace-root`

proc helpHint(sub: string): string =
  "; run `repro store " & sub & " --help` for its usage"

when defined(windows):
  proc runStoreBundleCommand*(sub: string; a: StoreBundleArgs;
                              hooks: StoreBundleCliHooks): int =
    ## Bundles need POSIX nanosecond timestamps (docs/store-bundles.md).
    stderr.writeLine("repro store " & sub &
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

  proc shellQuote(value: string): string =
    "'" & value.replace("'", "'\\''") & "'"

  proc freezeDevEnv*(projectRoot, storeRoot: string): FrozenDevEnv =
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
    let script = drainStream(p.outputStream)
    let errText = drainStream(p.errorStream)
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

  type SelectionInfo = object
    selector: string
    members: seq[string]

  proc closureJson(c: BundleClosure; info: SelectionInfo): JsonNode =
    var skipped = newJArray()
    for s in c.skippedRecords:
      skipped.add(%*{"edge": s.edgeDir, "record": s.strongHex,
        "kind": $s.kind, "reason": s.reason})
    var records = newJArray()
    for r in c.records:
      records.add(%*{"edge": r.edgeDir, "record": r.strongHex,
        "projectDir": r.outputRoot})
    %*{
      "producer": {"version": c.producer.version,
        "revision": c.producer.revision},
      "roots": {"storeRoot": c.roots.storeRoot,
        "actionCacheRoot": c.roots.actionCacheRoot,
        "workspaceRoots": %c.roots.workspaceRoots},
      "selection": {"selector": info.selector, "members": %info.members,
        "exclude": %c.selection.excluded, "include": %c.selection.included},
      "carriedRecords": records,
      "edges": %c.edges,
      "records": c.records.len,
      "prefixes": %c.prefixes,
      "entries": c.entries.len,
      "unpackedBytes": c.unpackedBytes,
      "restamps": c.restamps.len,
      "skippedRecords": skipped
    }

  proc printClosureText(c: BundleClosure; info: SelectionInfo) =
    echo "store root:        " & c.roots.storeRoot
    echo "action-cache root: " & c.roots.actionCacheRoot
    for r in c.roots.workspaceRoots:
      echo "workspace root:    " & r
    if info.selector.len > 0:
      echo "selection:         " & info.selector & " (" &
        info.members.join(", ") & ")"
    for d in c.selection.excluded:
      echo "  excluded:        " & d
    for d in c.selection.included:
      echo "  included:        " & d
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
        s.edgeDir.extractFilename & " (" & $s.kind & "): " & s.reason

  proc runStoreBundleCommand*(sub: string; a: StoreBundleArgs;
                              hooks: StoreBundleCliHooks): int =
    ## `repro store closure|export|import` (`sub`).
    var exportOpts = defaultExportOptions("")
    if a.partSize.len > 0 and not parseSize(a.partSize, exportOpts.partSize):
      stderr.writeLine("repro store " & sub & ": bad --part-size: " &
        "--part-size=" & a.partSize)
      return 2
    if a.zstdLevel.isSome: exportOpts.zstdLevel = a.zstdLevel.get
    if a.zstdThreads.isSome: exportOpts.zstdThreads = a.zstdThreads.get
    var roots = a.roots
    let freeze = a.freezeDevEnv
    let outDir = a.outDir
    let emitJson = a.emitJson
    var info = SelectionInfo(selector: a.selection)
    var selection = BundleSelection()
    let storeRoot = resolveStoreRoot(a.storeRoot)
    let acRoot = hooks.resolveActionCacheRoot(a.actionCacheRoot)
    try:
      if a.selection.len > 0 and sub in ["closure", "export"]:
        # The selection `repro bundle create` carries in its native half
        # (docs/store-bundles.md, "A selection of the roots").
        var ws = a.workspaceRoot
        if ws.len == 0 and hooks.workspaceRootFor != nil:
          ws = hooks.workspaceRootFor(getCurrentDir())
        if ws.len == 0:
          stderr.writeLine("repro store " & sub & ": --selection needs a " &
            "workspace; run it inside one or pass --workspace-root=DIR")
          return 2
        ws = normalizedPath(absolutePath(ws))
        let members = resolveMembers(ws, a.selection)
        for m in members:
          if m.checkedOut: info.members.add(m.relPath)
        selection = nativeSelection(ws, members,
          [normalizedPath(absolutePath(storeRoot)),
           normalizedPath(absolutePath(acRoot))])
        if ws notin roots:
          roots.insert(ws, 0)
    except CatchableError as e:
      stderr.writeLine("repro store " & sub & ": error: " & e.msg)
      return 1
    let local = BundleRoots(storeRoot: storeRoot, actionCacheRoot: acRoot,
      workspaceRoots: roots)
    try:
      case sub
      of "closure", "export":
        if roots.len == 0:
          stderr.writeLine("repro store " & sub & ": at least one --root=DIR " &
            "is required" & helpHint(sub))
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
        let closure = computeClosure(local, devEnvs, selection)
        warnPinnedUpstreamNim("store " & sub, closure.projectDirs)
        if sub == "closure":
          if emitJson: echo pretty(closureJson(closure, info))
          else: printClosureText(closure, info)
          return 0
        exportOpts.outDir = absolutePath(outDir)
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
        let report = importBundle(ImportOptions(bundleDir: a.bundleDir,
          force: a.force), local)
        if a.allowDevEnv:
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
