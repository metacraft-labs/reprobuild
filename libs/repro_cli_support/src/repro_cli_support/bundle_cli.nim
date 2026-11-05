## `repro bundle create | publish | restore` — the command-line face of
## `repro_bundle` (reprobuild docs/workspace-bundles.md). Parsing, root
## resolution and reports only; the behaviour is in the library.

import std/[json, os, strutils]
import repro_local_store/store
import repro_bundle

when not defined(windows):
  import repro_local_store/store_bundle
  import ./store_bundle_cli

type
  BundleCliHooks* = object
    resolveActionCacheRoot*: proc (explicit: string): string
    allowProject*: proc (projectRoot: string): int
    workspaceRootFor*: proc (startPath: string): string

const BundleUsage* = """usage:
  repro bundle create <selector> --out=DIR [--workspace-root=DIR] [--name=N]
      [--all-shells] [--primary=MEMBER:SHELL] [--no-nix] [--no-sources]
      [--no-native] [--native-root=DIR]... [--freeze-dev-env]
      [--zstd=STORE-PATH] [--repro=STORE-PATH] [--level=N] [--part-size=SIZE]
      [--check-stable] [--json]
  repro bundle publish <out>/<bundle> --to=s3://BUCKET[/PREFIX]
      [--endpoint=URL] [--region=R] [--parallel=N]
  repro bundle restore <url-or-dir> [--workspace=DIR] [--activate]
      [--activation-file=PATH] [--allow-dev-env] [--parallel=N]
      [--staging=DIR] [--nix-root=DIR] [--after-bootstrap] [--json]
common: [--store-root=PATH] [--action-cache-root=PATH]
Publishing reads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY from the environment.
See docs/workspace-bundles.md."""

proc mib(n: int64): string = $(n shr 20) & " MiB"

proc parseSizeArg(text: string; value: var int64): bool =
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

when defined(windows):
  proc runBundleCommand*(args: seq[string]; hooks: BundleCliHooks): int =
    stderr.writeLine("repro bundle: workspace bundles are not supported on " &
      "Windows")
    1
else:
  proc runBundleCommand*(args: seq[string]; hooks: BundleCliHooks): int =
    if args.len == 0 or args[0] in ["-h", "--help", "help"]:
      echo BundleUsage
      return (if args.len == 0: 2 else: 0)
    let sub = args[0]
    var positionals, nativeRoots: seq[string]
    var flags: seq[(string, string)]
    var switches: seq[string]
    for raw in args[1 .. ^1]:
      if raw.startsWith("--"):
        let eq = raw.find('=')
        if eq > 0:
          let key = raw[2 ..< eq]
          let value = raw[eq + 1 .. ^1]
          if key == "native-root": nativeRoots.add(value)
          else: flags.add((key, value))
        else:
          switches.add(raw[2 .. ^1])
      else:
        positionals.add(raw)
    proc flag(name: string; default = ""): string =
      result = default
      for (k, v) in flags:
        if k == name: result = v
    proc has(name: string): bool = name in switches
    let known = case sub
      of "create": @["out", "workspace-root", "name", "primary", "zstd",
        "repro", "level", "part-size", "store-root", "action-cache-root",
        "all-shells", "no-nix", "no-sources", "no-native", "freeze-dev-env",
        "check-stable", "json"]
      of "publish": @["to", "endpoint", "region", "parallel"]
      of "restore": @["workspace", "activation-file", "parallel", "staging",
        "nix-root", "store-root", "action-cache-root", "activate",
        "allow-dev-env", "after-bootstrap", "json"]
      else: @[]
    if known.len == 0:
      stderr.writeLine("repro bundle: unknown subcommand: " & sub & "\n" &
        BundleUsage)
      return 2
    for (k, _) in flags:
      if k notin known:
        stderr.writeLine("repro bundle " & sub & ": unknown flag: --" & k)
        return 2
    for k in switches:
      if k notin known:
        stderr.writeLine("repro bundle " & sub & ": unknown flag: --" & k)
        return 2
    let emitJson = has("json")
    try:
      case sub
      of "create":
        if positionals.len != 1:
          stderr.writeLine("repro bundle create: exactly one selector is " &
            "required\n" & BundleUsage)
          return 2
        let outDir = flag("out")
        if outDir.len == 0:
          stderr.writeLine("repro bundle create: --out=DIR is required")
          return 2
        var ws = flag("workspace-root")
        if ws.len == 0: ws = hooks.workspaceRootFor(getCurrentDir())
        if ws.len == 0:
          stderr.writeLine("repro bundle create: not inside a workspace; " &
            "pass --workspace-root=DIR")
          return 2
        var opts = CreateOptions(workspaceRoot: ws, selector: positionals[0],
          outDir: outDir, name: flag("name"), nix: not has("no-nix"),
          sources: not has("no-sources"), native: not has("no-native"))
        opts.nixOptions = NixHalfOptions(allShells: has("all-shells"),
          primary: flag("primary"), zstd: flag("zstd"), repro: flag("repro"),
          checkStable: has("check-stable"))
        if flag("level").len > 0: opts.level = parseInt(flag("level"))
        if flag("part-size").len > 0 and
            not parseSizeArg(flag("part-size"), opts.partSize):
          stderr.writeLine("repro bundle create: bad --part-size")
          return 2
        let storeRoot = resolveStoreRoot(flag("store-root"))
        opts.nativeRoots = BundleRoots(storeRoot: storeRoot,
          actionCacheRoot: hooks.resolveActionCacheRoot(
            flag("action-cache-root")), workspaceRoots: nativeRoots)
        if opts.native and has("freeze-dev-env"):
          for m in resolveMembers(ws, positionals[0]):
            if m.checkedOut and (fileExists(m.absPath / "repro.nim") or
                fileExists(m.absPath / "reprobuild.nim")):
              try:
                opts.devEnvs.add(freezeDevEnv(m.absPath, storeRoot))
              except CatchableError as e:
                stderr.writeLine("repro bundle create: dev env of " & m.name &
                  " not frozen: " & e.msg)
        let r = createBundle(opts)
        if emitJson:
          echo readFile(r.latestPath)
        else:
          for h in r.halves:
            echo h.kind.alignLeft(13) & h.id & (if h.reused: "  (unchanged)"
              else: "") & "  " & mib(h.compressedBytes) & " compressed, " &
              mib(h.unpackedBytes) & " unpacked"
          echo "total unpacked: " & mib(r.unpackedBytes) &
            " (the restoring disk must hold this)"
          echo "latest:  " & r.latestPath
          echo "restore: " & r.restoreScript
        return 0
      of "publish":
        if positionals.len != 1 or flag("to").len == 0:
          stderr.writeLine("repro bundle publish: a bundle directory and " &
            "--to=s3://BUCKET[/PREFIX] are required")
          return 2
        var po = PublishOptions(bundleDir: positionals[0], target: flag("to"),
          endpoint: flag("endpoint"), region: flag("region"))
        if flag("parallel").len > 0: po.parallel = parseInt(flag("parallel"))
        let r = publishBundle(po)
        for u in r.uploaded: echo "uploaded  " & u
        for s in r.skipped: echo "unchanged " & s
        echo "published " & r.baseUrl
        return 0
      of "restore":
        if positionals.len != 1:
          stderr.writeLine("repro bundle restore: exactly one bundle " &
            "directory or URL is required")
          return 2
        let storeRoot = resolveStoreRoot(flag("store-root"))
        let acRoot = hooks.resolveActionCacheRoot(flag("action-cache-root"))
        let allow = has("allow-dev-env")
        var ro = RestoreOptions(source: positionals[0],
          workspaceDir: flag("workspace"), nixRoot: flag("nix-root"),
          staging: flag("staging"), activate: has("activate"),
          activationFile: flag("activation-file"),
          afterBootstrap: has("after-bootstrap"), storeRoot: storeRoot,
          actionCacheRoot: acRoot)
        if flag("parallel").len > 0: ro.parallel = parseInt(flag("parallel"))
        ro.importNative = proc (dir: string): ImportReport =
          result = importBundle(ImportOptions(bundleDir: dir,
            manifestName: "native-store.json"),
            BundleRoots(storeRoot: storeRoot, actionCacheRoot: acRoot))
          if allow:
            for env in result.devEnvs:
              discard hooks.allowProject(env.projectRoot)
        let r = restoreBundle(ro)
        if emitJson:
          var phases = newJObject()
          for (p, s) in r.phaseSeconds: phases[p] = %s
          echo pretty(%*{"restored": r.restored,
            "alreadyPresent": r.alreadyPresent,
            "workspaceDir": r.workspaceDir, "primaryEnv": r.primaryEnv,
            "frozenDevEnv": r.frozenDevEnv,
            "activationFile": r.activationFile, "phaseSeconds": phases,
            "native": {"verifiedEntries": r.native.verifiedEntries,
              "rewitnessedRecords": r.native.rewitnessedRecords,
              "restamped": r.native.restamped}})
        else:
          for h in r.restored: echo "restored  " & h
          for h in r.alreadyPresent: echo "present   " & h
          for (p, s) in r.phaseSeconds:
            echo "  " & p.alignLeft(22) & formatFloat(s, ffDecimal, 1) & " s"
          if r.primaryEnv.len > 0: echo "dev shell: . " & r.primaryEnv
          if r.frozenDevEnv.len > 0: echo "repro dev env: . " & r.frozenDevEnv
          if r.activationFile.len > 0: echo "activated via " & r.activationFile
        return 0
      else:
        return 2
    except CatchableError as e:
      stderr.writeLine("repro bundle " & sub & ": error: " & e.msg)
      return 1
