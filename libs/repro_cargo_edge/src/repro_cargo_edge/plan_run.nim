## The record-only graph-production edge's process: run cargo's whole
## schedule in record mode, compiling nothing, and write the plan.
##
##   repro-rustc-wrapper --cargo-plan --plan FILE --scratch DIR
##       --cargo CARGO --rustc RUSTC [--store-root DIR]
##       [--crate NAME@VERSION=PREFIX]... -- [CARGO ARGS...]
##
## It runs in the workspace root (the edge's working directory) and does, in
## order:
##
## 1. Prepares the edge-private directories inside the scratch directory
##    (which the engine empties before the edge runs): the record directory,
##    the scratch target directory, an empty `CARGO_HOME` and an empty `HOME`.
##    Each must be absent or empty, and the saved metadata must not exist
##    yet: a recording or placeholder left by an earlier run would enter this
##    run's plan, and no single wrapper process can tell where a run starts,
##    so the edge checks. cargo never sees the user's `~/.cargo` or home
##    directory.
## 2. Refuses what it cannot plan from inside the workspace:
##    - a `Cargo.lock` package with a `source` other than crates.io (a git
##      or alternate-registry dependency); a crates.io package whose name,
##      version or checksum is malformed (`crate_rows.validateRow`), that was
##      given no `--crate` prefix, or whose prefix is not that crate's store
##      prefix (`checkPrefix`: no `..`, resolved under the resolved store
##      root, named for that name, version and checksum, holding that
##      package's manifest); a `--crate` given twice or for a crate the lock
##      does not hold; a `[patch]` or `[replace]` table in the workspace's
##      `Cargo.toml`; and `paths`, `[source]`, `[patch]` or `include` in its
##      `.cargo/config.toml` (or `.cargo/config`): the cases the edge does
##      not cover, which stay with cargo as a whole;
##    - a cargo configuration file (`.cargo/config.toml` or `.cargo/config`)
##      in any directory above the workspace root: cargo reads every one of
##      them, so the plan would depend on a file outside the workspace
##      (Cargo Book, "Configuration", "Hierarchical structure":
##      https://doc.rust-lang.org/cargo/reference/config.html#hierarchical-structure);
##    - a workspace package (one with no source) whose manifest is outside
##      the workspace root, read from the saved `cargo metadata`: its paths
##      would be paths of this host only;
##    - cargo arguments outside the selection this edge models
##      (`validateCargoArgs`).
## 3. Serves cargo the crates.io crates from their store prefixes. A
##    `directory` source needs a `.cargo-checksum.json` in each crate
##    directory, and a prefix is a read-only extraction without one, so the
##    edge writes, in its scratch directory, a VENDOR directory with one entry
##    `<name>-<version>` per locked crate: a symbolic link to each top-level
##    entry of the crate's prefix and a `.cargo-checksum.json` of
##    `{"files":{},"package":"<checksum from Cargo.lock>"}`
##    (`cargo_lock.cargoChecksumJson`; cargo checks the package checksum
##    against the lock, and an empty `files` map claims nothing per file:
##    https://doc.rust-lang.org/cargo/reference/source-replacement.html#directory-sources).
##    Two `--config` values replace `crates-io` with that directory, for
##    `cargo metadata` and `cargo build` alike, on the command line so that no
##    configuration file outranks them. The prefixes are only read.
##    Saves `cargo metadata --offline --locked --format-version 1` for the
##    recording stub, which reads each package's targets from it, and checks
##    it (`checkServedManifests`): cargo's workspace root is the working
##    directory, and every package with a source was read from exactly its
##    vendor entry's manifest. That is the positive check behind the
##    refusals above: whatever a configuration could do to re-route a
##    source, cargo's own answer says where each crate came from.
## 4. Runs `cargo build --offline --locked -j 1 --target-dir <scratch>/target`
##    with the given arguments (the build's profile, target and package
##    selection) and four `--config` values: the record wrapper as
##    `build.rustc-wrapper`, the given rustc as `build.rustc`, an empty
##    `build.rustc-workspace-wrapper` (a project's own workspace wrapper would
##    otherwise run between the record wrapper and rustc, for probes too),
##    and `build.build-dir` set to the scratch target directory (a project's
##    `build.build-dir` would otherwise move cargo's intermediate files,
##    placeholders and stubs included, outside the scratch directory).
##    Passing them on the command line keeps them out of a unit's
##    environment, and the command line outranks configuration files and
##    `CARGO_BUILD_*` variables. `-j 1` makes the `NUM_JOBS` cargo gives each
##    build script the same on every host.
## 5. Derives the plan from the recordings (`cargo_plan.derivePlan`), with
##    each vendor entry (`${scratch}/vendor/<name>-<version>`) mapped back
##    to the prefix it was made from, read from the entries this run wrote,
##    and writes it to the plan file, the edge's one declared output.
##
## The recordings name paths against the roots `project` (the working
## directory), `target` (the scratch target directory), `scratch`, `store`
## when given, and `nix` (`/nix/store`) where that store exists. Only the
## plan leaves the edge; the scratch directory, the recordings with it, is
## the engine's to empty.
##
## `RUSTC`, `RUSTC_WRAPPER` and `RUSTC_WORKSPACE_WRAPPER` in the environment
## are refused: cargo lets those three outrank its configuration, the command
## line's included (measured for `RUSTC_WRAPPER` with cargo 1.94: the
## variable's wrapper ran and the `--config` one did not), so the record run
## would compile for real.
##
## Exit codes: 0 with the plan written, 2 usage, 1 any other failure (the
## message names it). POSIX only, as record mode is.

import std/[algorithm, json, os, sets, strutils, tables]

import toml_serialization
import toml_serialization/types as toml_types
when defined(posix):
  import std/posix

import repro_core/cargo_lock
import repro_cargo_fetch/[crate_identity, crate_rows]
import repro_local_store/prefix_location

import ./[cargo_plan, record_mode]

const
  PlanRunFlag* = "--cargo-plan"
    ## The wrapper's argv[1] that selects this command. Cargo runs the
    ## wrapper with a rustc path there, never with this flag.
  PlanRunUsage* = "usage: repro-rustc-wrapper " & PlanRunFlag &
    " --plan FILE --scratch DIR --cargo CARGO --rustc RUSTC " &
    "[--store-root DIR] -- [CARGO ARGS...]\n"
  RecordSubdir* = "record"
  TargetSubdir* = "target"
  CargoHomeSubdir* = "cargo-home"
  HomeSubdir* = "home"
  MetadataFile* = "metadata.json"
  VendorSubdir* = "vendor"
  VendorSourceName = "repro-store-crates"
    ## The name of the replacement source in the record run's configuration.
  OverridingVariables* = ["RUSTC", "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER"]
  NixStore = "/nix/store"
  SelectionFlags = ["--release", "--workspace", "--all", "--lib", "--bins",
    "--all-features", "--no-default-features"]
    ## The cargo flags without a value the edge passes through.
  SelectionOptions = ["--profile", "--target", "--package", "-p",
    "--exclude", "--bin", "--features", "-F"]
    ## The cargo options with a value the edge passes through.

type
  CratePrefix* = object
    ## A locked crates.io crate and the store prefix its fetch edge made.
    name*, version*, prefix*: string

  PlanRunOptions* = object
    planFile*, scratch*: string
    cargo*, rustc*: string
    storeRoot*: string
    crates*: seq[CratePrefix]
    cargoArgs*: seq[string]

  PlanRunError* = object of CatchableError

proc fail(msg: string) {.noreturn.} =
  raise newException(PlanRunError, msg)

proc parsePlanRunArgs*(args: openArray[string]): PlanRunOptions =
  ## The options after `--cargo-plan`. Raises `PlanRunError` on a usage error.
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--":
      result.cargoArgs = @(args[i + 1 .. ^1])
      break
    if i + 1 >= args.len:
      fail("the option " & a & " takes a value")
    let value = args[i + 1]
    case a
    of "--plan": result.planFile = value
    of "--scratch": result.scratch = value
    of "--cargo": result.cargo = value
    of "--rustc": result.rustc = value
    of "--store-root": result.storeRoot = value
    of "--crate":
      let at = value.find('@')
      let eq = value.find('=')
      if at <= 0 or eq <= at + 1 or eq == value.high:
        fail("--crate takes NAME@VERSION=PREFIX, not " & value)
      result.crates.add CratePrefix(name: value[0 ..< at],
        version: value[at + 1 ..< eq], prefix: value[eq + 1 .. ^1])
    else: fail("unexpected argument '" & a & "'")
    i += 2
  for (name, value) in [("--plan", result.planFile),
      ("--scratch", result.scratch), ("--cargo", result.cargo),
      ("--rustc", result.rustc)]:
    if value.len == 0: fail(name & " is required")

proc validateCargoArgs*(args: openArray[string]): string =
  ## "" when `args` hold only the build selection this edge models (the
  ## profile, the target, the packages, binaries and features), else why
  ## not. Anything else (`--config`, `--target-dir`, `--manifest-path`, `-j`,
  ## `-Z`, test or example targets, ...) would change what the edge itself
  ## sets or plan units this edge does not cover.
  var i = 0
  while i < args.len:
    let a = args[i]
    if a in SelectionFlags:
      inc i
      continue
    var known = false
    for opt in SelectionOptions:
      if a == opt:
        if i + 1 >= args.len or args[i + 1].startsWith("-"):
          return "the cargo option " & a & " takes a value"
        i += 2
        known = true
        break
      if opt.startsWith("--") and a.startsWith(opt & "="):
        inc i
        known = true
        break
    if not known:
      return "the cargo argument " & a.escape() & " is outside the build " &
        "selection the record run passes through"
  ""

proc crateArg*(c: CratePrefix): string =
  ## The `--crate` argument naming `c`.
  c.name & "@" & c.version & "=" & c.prefix

proc tomlTable(path, what: string): TomlValueRef =
  try:
    Toml.decode(readFile(path), TomlValueRef)
  except CatchableError as err:
    fail(what & " " & path & " does not parse: " & err.msg)

proc hasKey(table: TomlValueRef; key: string): bool =
  not table.isNil and table.kind in {TomlKind.Table, TomlKind.InlineTable} and
    table.tableVal[].hasKey(key)

proc realPath(path: string): string =
  ## `path` with every symbolic link resolved, or "" when it does not exist.
  try: expandFilename(path)
  except OSError: ""

proc hasParentComponent(path: string): bool =
  for part in path.split('/'):
    if part == "..": return true
  false

proc checkPrefix(c: CratePrefix; cksum, storeRoot: string): string =
  ## "" when `c.prefix` IS the store prefix of `c` with checksum `cksum`,
  ## else why not. The prefix must be spelled without `..`, resolve (links
  ## followed) to a directory under the resolved store root, have there the
  ## name the store gives that crate's realization (`<store>/prefixes/<name>/
  ## <version>-<realization hash>`, a function of the name, the version and
  ## the checksum: `crate_identity`), and hold the manifest of that package
  ## and version.
  let label = c.name & "@" & c.version
  if not c.prefix.isAbsolute or hasParentComponent(c.prefix):
    return label & "'s prefix " & c.prefix & " is not an absolute path " &
      "without `..`"
  if storeRoot.len == 0:
    return label & " was given a prefix, but the edge has no store root"
  let real = realPath(c.prefix)
  let realStore = realPath(storeRoot)
  if real.len == 0 or not dirExists(real):
    return label & "'s prefix " & c.prefix & " does not exist"
  if realStore.len == 0 or not real.startsWith(realStore & "/"):
    return label & "'s prefix " & c.prefix & " is outside the store root"
  let id = crateRealizationId(CrateRow(name: c.name, version: c.version,
    cksum: cksum))
  if not isPrefixPathOf(real[realStore.len + 1 .. ^1], c.name, c.version, id):
    return label & "'s prefix " & c.prefix & " is not the store's prefix " &
      "of that crate with the checksum Cargo.lock records"
  if not fileExists(real / "Cargo.toml"):
    return label & "'s prefix " & c.prefix & " holds no Cargo.toml"
  let manifest = tomlTable(real / "Cargo.toml", "the crate manifest")
  var name, version = ""
  if manifest.hasKey("package"):
    let pkg = manifest.tableVal[]["package"]
    for (key, into) in [("name", addr name), ("version", addr version)]:
      if pkg.hasKey(key) and pkg.tableVal[][key].kind == TomlKind.String:
        into[] = pkg.tableVal[][key].stringVal
  if name != c.name or version != c.version:
    return label & "'s prefix " & c.prefix & " holds the manifest of " &
      name & "@" & version
  ""

const RefusedConfigKeys = ["paths", "source", "patch", "include"]
  ## Keys of the project's cargo configuration the record run refuses: each
  ## changes where cargo takes a package's sources from (`paths` and
  ## `[patch]` override packages, `[source]` can re-route the replacement
  ## the run sets on the command line, since cargo merges the command line
  ## with the files and follows `replace-with` through them, and `include`
  ## pulls in other files).

proc checkSources(project, storeRoot: string; crates: openArray[CratePrefix]):
    seq[(CratePrefix, string)] =
  ## The locked crates.io crates with their `Cargo.lock` checksums, each
  ## matched to its `--crate` prefix; raises on what the edge does not cover
  ## (see the module docstring, step 2).
  var given = initTable[string, CratePrefix]()
  for c in crates:
    let label = c.name & "@" & c.version
    if label in given:
      fail("the crate " & label & " was given more than one prefix")
    given[label] = c
  if not fileExists(project / "Cargo.toml"):
    return   # cargo itself refuses a directory with no manifest
  let manifest = tomlTable(project / "Cargo.toml", "the workspace manifest")
  for key in ["patch", "replace"]:
    if manifest.hasKey(key):
      fail("the workspace manifest has a [" & key & "] table, which the " &
        "record run does not model")
  for name in ["config.toml", "config"]:
    let config = project / ".cargo" / name
    if fileExists(config):
      let table = tomlTable(config, "the cargo configuration")
      for key in RefusedConfigKeys:
        if table.hasKey(key):
          fail("the cargo configuration " & config & " sets `" & key &
            "`, which the record run does not model")
  var problems: seq[string]
  var locked = initHashSet[string]()
  if fileExists(project / "Cargo.lock"):
    for pkg in parseCargoLock(readFile(project / "Cargo.lock")):
      if pkg.source.len == 0: continue
      let label = pkg.name & "@" & pkg.version
      locked.incl label
      if not isRegistrySource(pkg.source):
        problems.add label & " comes from " & pkg.source & ", which is not " &
          "crates.io"
        continue
      try:
        validateRow(CrateRow(name: pkg.name, version: pkg.version,
          cksum: pkg.checksum))
      except CrateRowError as err:
        problems.add err.msg
        continue
      if label notin given:
        problems.add label & " was given no store prefix"
        continue
      let problem = checkPrefix(given[label], pkg.checksum, storeRoot)
      if problem.len > 0: problems.add problem
      else:
        # Served from the resolved prefix, the one the checks were made on.
        var c = given[label]
        c.prefix = realPath(c.prefix)
        result.add (c, pkg.checksum)
  for label in given.keys:
    if label notin locked:
      problems.add label & " was given a prefix but Cargo.lock does not " &
        "lock it from crates.io"
  if problems.len > 0:
    problems.sort()
    fail("Cargo.lock holds packages the record run cannot serve: " &
      problems.join("; "))

proc checkServedManifests*(metadata: JsonNode; project: string;
                           served: openArray[(string, string, string)]) =
  ## After `cargo metadata`: the workspace is the one in `project` (cargo
  ## found no enclosing workspace with its own lock or patches), and every
  ## package with a source is one of `served` (name, version, the manifest
  ## of its vendor entry) and was read from exactly that manifest, so no
  ## configuration re-routed it. Raises `PlanRunError`.
  let root = metadata{"workspace_root"}.getStr
  if root.len == 0 or realPath(root) != realPath(project):
    fail("cargo's workspace root is " & root.escape() & ", not the " &
      "record run's working directory " & project)
  var expected = initTable[string, string]()
  for (name, version, manifestPath) in served:
    expected[name & "@" & version] = manifestPath
  var seen = initHashSet[string]()
  for pkg in metadata{"packages"}.getElems():
    let source = pkg{"source"}
    if source.isNil or source.kind == JNull: continue
    let label = pkg{"name"}.getStr & "@" & pkg{"version"}.getStr
    let manifestPath = pkg{"manifest_path"}.getStr
    if label notin expected:
      fail("cargo resolved " & label & " from " & source.getStr &
        ", which the record run did not serve")
    if manifestPath != expected[label]:
      fail("cargo read " & label & " from " & manifestPath & ", not from " &
        "the record run's vendor entry " & expected[label])
    seen.incl label
  for label in expected.keys:
    if label notin seen:
      fail("cargo did not read the served crate " & label)

proc writeVendorDir(vendor: string; crates: openArray[(CratePrefix, string)]):
    seq[(string, string)] =
  ## One entry per crate (see the module docstring, step 3); returns each
  ## entry's directory with the prefix it links to.
  createDir(vendor)
  for (c, cksum) in crates:
    let dir = vendor / (c.name & "-" & c.version)
    createDir(dir)
    for kind, path in walkDir(c.prefix):
      let name = extractFilename(path)
      if name == ".cargo-checksum.json": continue
      createSymlink(path, dir / name)
    writeFile(dir / ".cargo-checksum.json", cargoChecksumJson(VendorEntry(
      name: c.name, version: c.version, sha256: cksum)))
    result.add (dir, c.prefix)

proc emptyOrAbsent(dir, what: string) =
  if fileExists(dir) or symlinkExists(dir):
    fail(what & " " & dir & " is not a directory")
  if dirExists(dir):
    for _ in walkDir(dir):
      fail(what & " " & dir & " is not empty at the start of the run")
  createDir(dir)

when defined(posix):
  when defined(macosx):
    # macOS's <unistd.h> does not declare `environ`, and a shared library
    # cannot link against it; Apple's documented accessor is _NSGetEnviron()
    # from <crt_externs.h>, which returns the address of the live variable
    # (environ(7), https://developer.apple.com/library/archive/documentation/
    # System/Conceptual/ManPages_iPhoneOS/man7/environ.7.html). Nim's own
    # std/envvars reads the environment the same way on macOS.
    proc nsGetEnviron(): ptr cstringArray {.importc: "_NSGetEnviron",
      header: "<crt_externs.h>".}

    proc processEnviron(): cstringArray =
      ## The current `environ`, re-read on every call: `setenv` may replace
      ## the array, so a cached pointer could name a freed one.
      nsGetEnviron()[]
  else:
    var environ {.importc, header: "<unistd.h>".}: cstringArray

    proc processEnviron(): cstringArray =
      ## The current `environ` (see the macOS branch for why it is a call).
      environ

  proc spawnWait*(argv: openArray[string]; stdoutFile = ""): int =
    ## Run `argv` (argv[0] a path) with this process's environment and
    ## standard streams, standard output redirected to `stdoutFile` when one
    ## is given, and wait for it. Returns its exit status (128 + the signal
    ## when it was killed). Exported for its test
    ## (`tests/t_plan_run_spawn_environment`); the edge calls it internally.
    var actions: Tposix_spawn_file_actions
    if posix_spawn_file_actions_init(actions) != 0:
      fail("posix_spawn_file_actions_init failed")
    defer: discard posix_spawn_file_actions_destroy(actions)
    var fd: cint = -1
    if stdoutFile.len > 0:
      fd = posix.open(stdoutFile.cstring, O_WRONLY or O_CREAT or O_TRUNC,
        0o644)
      if fd < 0: fail("cannot create " & stdoutFile)
      if posix_spawn_file_actions_adddup2(actions, fd, 1) != 0:
        fail("posix_spawn_file_actions_adddup2 failed")
    defer:
      if fd >= 0: discard posix.close(fd)
    let cargv = allocCStringArray(argv)
    defer: deallocCStringArray(cargv)
    var attr: Tposix_spawnattr
    if posix_spawnattr_init(attr) != 0:
      fail("posix_spawnattr_init failed")
    defer: discard posix_spawnattr_destroy(attr)
    var pid: Pid
    let rc = posix_spawn(pid, argv[0].cstring, actions, attr, cargv,
      processEnviron())
    if rc != 0:
      fail("cannot start " & argv[0] & ": " & $strerror(rc))
    var status: cint
    while waitpid(pid, status, 0) < 0:
      if errno != EINTR: fail("waitpid failed for " & argv[0])
    if WIFEXITED(status): int(WEXITSTATUS(status))
    elif WIFSIGNALED(status): 128 + int(WTERMSIG(status))
    else: 1

proc tomlString(s: string): string =
  ## A TOML basic string for a `--config` value.
  result = "\""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    else: result.add ch
  result.add "\""

proc runCargoPlan*(opts: PlanRunOptions): int =
  ## The edge's process (see the module docstring). Raises `PlanRunError`
  ## (or `CargoPlanError`, `RecordModeError`) on failure.
  when not defined(posix):
    fail("the record run is not supported on this platform")
  else:
    let project = getCurrentDir()
    let scratch = absolutePath(opts.scratch)
    if project == scratch or project.startsWith(scratch & "/"):
      fail("the scratch directory " & scratch & " contains the workspace")
    for name in OverridingVariables:
      if existsEnv(name):
        fail("the environment sets " & name & ", which outranks the " &
          "record run's own compiler and wrapper; the record run cannot " &
          "honour it")
    createDir(scratch)
    let recordDirPath = scratch / RecordSubdir
    emptyOrAbsent(recordDirPath, "the record directory")
    let cargoHome = scratch / CargoHomeSubdir
    emptyOrAbsent(cargoHome, "the edge-private CARGO_HOME")
    let home = scratch / HomeSubdir
    emptyOrAbsent(home, "the edge-private HOME")
    let targetDir = scratch / TargetSubdir
    emptyOrAbsent(targetDir, "the scratch target directory")
    let metadataPath = scratch / MetadataFile
    if fileExists(metadataPath) or symlinkExists(metadataPath) or
        dirExists(metadataPath):
      fail("the saved metadata " & metadataPath & " exists at the start of " &
        "the run")
    let argsProblem = validateCargoArgs(opts.cargoArgs)
    if argsProblem.len > 0: fail(argsProblem)
    block ancestors:
      var dir = parentDir(project)
      while dir.len > 0:
        for name in ["config.toml", "config"]:
          let config = dir / ".cargo" / name
          if fileExists(config):
            fail("cargo would read the configuration file " & config &
              ", which is outside the workspace")
        let up = parentDir(dir)
        if up == dir or up.len == 0: break
        dir = up

    let served = checkSources(project, opts.storeRoot, opts.crates)
    let vendor = scratch / VendorSubdir
    emptyOrAbsent(vendor, "the vendor directory")
    let vendorEntries = writeVendorDir(vendor, served)
    var servedManifests: seq[(string, string, string)]
    for i, (c, _) in served:
      servedManifests.add (c.name, c.version,
        vendorEntries[i][0] / "Cargo.toml")
    let sourceConfig = @[
      "--config", "source.crates-io.replace-with=" &
        tomlString(VendorSourceName),
      "--config", "source." & VendorSourceName & ".directory=" &
        tomlString(vendor)]

    putEnv("CARGO_HOME", cargoHome)
    putEnv("HOME", home)

    var rootLines = @["project=" & project, TargetRootLabel & "=" & targetDir,
      ScratchRootLabel & "=" & scratch]
    if opts.storeRoot.len > 0:
      rootLines.add "store=" & absolutePath(opts.storeRoot)
    if dirExists(NixStore):
      rootLines.add "nix=" & NixStore
    let roots = withResolvedSpellings(parseRecordRoots(rootLines.join("\n")))

    # The record run's own environment, as the recordings will name it: the
    # base every recorded environment is stored as a difference from.
    var baseEnv: seq[(string, string)]
    for name, value in envPairs():
      if not recordedEnvSkipped(name):
        baseEnv.add (name, logicalize(roots, value))
    baseEnv.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))

    # The same compiler, and no project wrapper, for the rustc queries
    # `cargo metadata` may make.
    let metaCode = spawnWait(@[opts.cargo,
      "--config", "build.rustc=" & tomlString(opts.rustc),
      "--config", "build.rustc-wrapper=" & tomlString(""),
      "--config", "build.rustc-workspace-wrapper=" & tomlString("")] &
      sourceConfig & @["metadata", "--offline", "--locked",
      "--format-version", "1"], stdoutFile = metadataPath)
    if metaCode != 0:
      fail("cargo metadata failed with exit status " & $metaCode)
    block outsideMembers:
      let metadata = parseFile(metadataPath)
      checkServedManifests(metadata, project, servedManifests)
      var outside: seq[string]
      for pkg in metadata{"packages"}.getElems():
        let source = pkg{"source"}
        if not source.isNil and source.kind != JNull: continue
        let manifest = pkg{"manifest_path"}.getStr
        if not logicalize(roots, manifest).startsWith("${project}/"):
          outside.add pkg{"name"}.getStr & " (" & manifest & ")"
      if outside.len > 0:
        outside.sort()
        fail("workspace packages outside the workspace root: " &
          outside.join(", ") & "; their paths would name files of this " &
          "host only")

    let wrapper = getAppFilename()
    putEnv(RecordDirEnv, recordDirPath)
    putEnv(RecordRootsEnv, rootLines.join("\n"))
    putEnv(RecordMetadataEnv, metadataPath)
    var build = @[opts.cargo,
      "--config", "build.rustc=" & tomlString(opts.rustc),
      "--config", "build.rustc-wrapper=" & tomlString(wrapper),
      "--config", "build.rustc-workspace-wrapper=" & tomlString(""),
      "--config", "build.build-dir=" & tomlString(targetDir)] & sourceConfig &
      @["build", "--offline", "--locked", "-j", "1",
      "--target-dir", targetDir]
    build.add opts.cargoArgs
    let code = spawnWait(build)
    delEnv(RecordDirEnv)
    delEnv(RecordRootsEnv)
    delEnv(RecordMetadataEnv)
    if code != 0:
      fail("the record run's cargo build failed with exit status " & $code)

    let recordings = readRecordings(recordDirPath)
    # Each vendor entry as the recordings name it, mapped to the prefix this
    # run linked it to.
    var vendorMap: seq[(string, string)]
    for (dir, prefix) in vendorEntries:
      vendorMap.add (logicalize(roots, dir), logicalize(roots, prefix))
    let plan = derivePlan(recordings, baseEnv, logicalize(roots, wrapper),
      vendorMap)
    let planPath = absolutePath(opts.planFile)
    createDir(parentDir(planPath))
    writeCargoPlan(planPath, plan)
    0

proc runPlanCommand*(args: openArray[string]): int =
  ## `args` are the arguments after `--cargo-plan`.
  var opts: PlanRunOptions
  try:
    opts = parsePlanRunArgs(args)
  except PlanRunError as err:
    stderr.writeLine "repro-rustc-wrapper " & PlanRunFlag & ": " & err.msg
    stderr.write PlanRunUsage
    return 2
  try:
    runCargoPlan(opts)
  except CatchableError as err:
    stderr.writeLine "repro-rustc-wrapper " & PlanRunFlag & ": " & err.msg
    1
