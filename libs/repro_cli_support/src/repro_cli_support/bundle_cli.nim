## `repro bundle create | publish | restore` — the command-line face of
## `repro_bundle` (reprobuild docs/workspace-bundles.md). Root resolution and
## reports only: the command line is parsed from repro's description
## (`repro_cli_support/cli_description`), and the behaviour is in the library.

import std/[json, options, os, strutils]
import repro_local_store/store

when not defined(windows):
  import repro_bundle
  import repro_local_store/store_bundle
  import ./store_bundle_cli

type
  BundleCliHooks* = object
    resolveActionCacheRoot*: proc (explicit: string): string
    allowProject*: proc (projectRoot: string): int
    workspaceRootFor*: proc (startPath: string): string

  BundleArgs* = object
    ## What `repro bundle create|publish|restore` was given; each subcommand
    ## reads the fields its flags fill.
    positional*: string        ## the selector, bundle directory or source
    outDir*: string            ## `create --out`
    workspaceRoot*: string     ## `create --workspace-root`
    name*: string              ## `create --name`
    primary*: string           ## `create --primary`
    zstd*: string              ## `create --zstd`
    repro*: string             ## `create --repro`
    level*: Option[int]        ## `create --level`
    partSize*: string          ## `create --part-size`
    nativeRoots*: seq[string]  ## `create --native-root`, repeated
    allShells*: bool           ## `create --all-shells`
    noNix*: bool               ## `create --no-nix`
    noSources*: bool           ## `create --no-sources`
    noNative*: bool            ## `create --no-native`
    freezeDevEnv*: bool        ## `create --freeze-dev-env`
    checkStable*: bool         ## `create --check-stable`
    to*: string                ## `publish --to`
    endpoint*: string          ## `publish --endpoint`
    region*: string            ## `publish --region`
    parallel*: Option[int]     ## `publish|restore --parallel`
    workspace*: string         ## `restore --workspace`
    activationFile*: string    ## `restore --activation-file`
    bashrcFile*: string        ## `restore --bashrc-file`
    staging*: string           ## `restore --staging`
    nixRoot*: string           ## `restore --nix-root`
    activate*: bool            ## `restore --activate`
    allowDevEnv*: bool         ## `restore --allow-dev-env`
    afterBootstrap*: bool      ## `restore --after-bootstrap`
    latestSha256*: string      ## `restore --latest-sha256`
    storeRoot*: string         ## `--store-root`
    actionCacheRoot*: string   ## `--action-cache-root`
    emitJson*: bool            ## `--json`

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
  proc runBundleCommand*(sub: string; a: BundleArgs;
                         hooks: BundleCliHooks): int =
    stderr.writeLine("repro bundle: workspace bundles are not supported on " &
      "Windows")
    1
else:
  proc runBundleCommand*(sub: string; a: BundleArgs;
                         hooks: BundleCliHooks): int =
    ## `repro bundle create|publish|restore` (`sub`).
    let emitJson = a.emitJson
    try:
      case sub
      of "create":
        let outDir = a.outDir
        if outDir.len == 0:
          stderr.writeLine("repro bundle create: --out=DIR is required")
          return 2
        var ws = a.workspaceRoot
        if ws.len == 0: ws = hooks.workspaceRootFor(getCurrentDir())
        if ws.len == 0:
          stderr.writeLine("repro bundle create: not inside a workspace; " &
            "pass --workspace-root=DIR")
          return 2
        var opts = CreateOptions(workspaceRoot: ws, selector: a.positional,
          outDir: outDir, name: a.name, nix: not a.noNix,
          sources: not a.noSources, native: not a.noNative)
        opts.nixOptions = NixHalfOptions(allShells: a.allShells,
          primary: a.primary, zstd: a.zstd, repro: a.repro,
          checkStable: a.checkStable)
        if a.level.isSome: opts.level = a.level.get
        if a.partSize.len > 0 and
            not parseSizeArg(a.partSize, opts.partSize):
          stderr.writeLine("repro bundle create: bad --part-size")
          return 2
        let storeRoot = resolveStoreRoot(a.storeRoot)
        opts.nativeRoots = BundleRoots(storeRoot: storeRoot,
          actionCacheRoot: hooks.resolveActionCacheRoot(
            a.actionCacheRoot), workspaceRoots: a.nativeRoots)
        if opts.native and a.freezeDevEnv:
          for m in resolveMembers(ws, a.positional):
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
        if a.to.len == 0:
          stderr.writeLine("repro bundle publish: a bundle directory and " &
            "--to=s3://BUCKET[/PREFIX] are required")
          return 2
        var po = PublishOptions(bundleDir: a.positional, target: a.to,
          endpoint: a.endpoint, region: a.region)
        if a.parallel.isSome: po.parallel = a.parallel.get
        let r = publishBundle(po)
        for u in r.uploaded: echo "uploaded  " & u
        for s in r.skipped: echo "unchanged " & s
        echo "published " & r.baseUrl
        return 0
      of "restore":
        let storeRoot = resolveStoreRoot(a.storeRoot)
        let acRoot = hooks.resolveActionCacheRoot(a.actionCacheRoot)
        let allow = a.allowDevEnv
        var ro = RestoreOptions(source: a.positional,
          workspaceDir: a.workspace, nixRoot: a.nixRoot,
          staging: a.staging, activate: a.activate,
          activationFile: a.activationFile,
          bashrcFile: a.bashrcFile,
          afterBootstrap: a.afterBootstrap, latestSha256: a.latestSha256,
          storeRoot: storeRoot,
          actionCacheRoot: acRoot)
        if a.parallel.isSome: ro.parallel = a.parallel.get
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
            "activationFile": r.activationFile, "bashrcFile": r.bashrcFile,
            "notes": r.notes, "phaseSeconds": phases,
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
          for n in r.notes: echo "note: " & n
          if r.activationFile.len > 0:
            echo "activated via " & r.activationFile & " (sourced from " &
              r.bashrcFile & ")"
        return 0
      of "inspect":
        # docs/store-bundles.md §7 / docs/workspace-bundles.md: verified, and
        # writes nothing.
        let r = inspectBundle(a.positional)
        if emitJson:
          echo pretty(r)
          return 0
        if r{"kind"}.getStr() == "workspace":
          echo "bundle:            " & r{"name"}.getStr() & " (" &
            r{"system"}.getStr() & "), selector " & r{"selector"}.getStr()
          var members: seq[string]
          for m in r{"members"}.getElems(): members.add(m.getStr())
          echo "members:           " & members.join(", ")
        let producer = r{"producer"}
        if producer.isNil or producer.kind != JObject:
          echo "repro:             (not recorded)"
        else:
          echo "repro:             " & producer{"version"}.getStr() &
            " (revision " & producer{"revision"}.getStr() & ")"
        echo "roots to provision:"
        let pr = r{"provision"}
        for (label, key) in [("workspace dir", "workspaceDir"),
                             ("store root", "storeRoot"),
                             ("action-cache root", "actionCacheRoot"),
                             ("nix store", "nixStore")]:
          if pr.hasKey(key):
            echo "  " & alignLeft(label & ":", 19) & pr[key].getStr()
        for w in pr{"workspaceRoots"}.getElems():
          echo "  workspace root:    " & w.getStr()
        for d in r{"selection"}{"exclude"}.getElems():
          echo "excluded:          " & d.getStr()
        for d in r{"selection"}{"include"}.getElems():
          echo "included:          " & d.getStr()
        for kind, id in r{"halves"}:
          echo alignLeft(kind & ":", 19) & id.getStr()
        return 0
      else:
        return 2
    except CatchableError as e:
      stderr.writeLine("repro bundle " & sub & ": error: " & e.msg)
      return 1
