## NF-4 — the contract of the foreign-environment stdlib helpers.
##
## Covers the parts of `Nix-Flake-Coexistence.md` §2b that are decidable
## without running `nix`: the shape of the command Reprobuild issues, the
## environment DIFF that becomes the dev-env contribution, the two auto-load
## flags, the precedence between them, the synthesised `repro.nim` that
## makes auto-load one code path rather than two, and — the one change NF-4
## makes to what the engine treats as an input — exactly which paths the
## dev-env introspection edge stops recording.
##
## MOCKS: none. Every case runs against the real filesystem (`createTempDir`
## plus real `.envrc` / `flake.nix` / `repro.nim` files) or against pure
## functions with no boundary at all. The nix-dependent half of NF-4 lives in
## `tests/e2e/dev-env/t_e2e_nf4_flake_dev_shell.nim`, which runs a real `nix`.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]

import repro_dev_env_engine
import repro_dev_env_engine/cache_key
import repro_dsl_stdlib/foreign_env
import repro_local_store

proc describeOps(ops: openArray[ForeignEnvOp]): string =
  var parts: seq[string] = @[]
  for op in ops:
    parts.add($op.kind & ":" & op.name)
  parts.join(", ")

proc opFor(ops: openArray[ForeignEnvOp]; name: string;
           kind: ForeignEnvOpKind): ForeignEnvOp =
  for op in ops:
    if op.name == name and op.kind == kind:
      return op
  raise newException(ValueError,
    "no " & $kind & " op for " & name & " in [" & describeOps(ops) & "]")

proc hasOpKind(ops: openArray[ForeignEnvOp]; name: string;
               kind: ForeignEnvOpKind): bool =
  for op in ops:
    if op.name == name and op.kind == kind:
      return true
  false

proc hasOpFor(ops: openArray[ForeignEnvOp]; name: string): bool =
  for op in ops:
    if op.name == name:
      return true
  false

suite "nf4_foreign_env_contract":

  test "the_flake_activation_is_one_line_in_repro_nim":
    # The owner's requirement, made checkable: activating a whole flake must
    # reduce to ONE line of `repro.nim` with no arguments to work out.
    let oneLiner = foreignEnvOneLiner(fesFlake)
    check oneLiner == "useFlakeDevShell()"
    check not oneLiner.contains('\n')
    check foreignEnvOneLiner(fesEnvrc) == "useEnvrc()"
    check not foreignEnvOneLiner(fesEnvrc).contains('\n')
    check foreignEnvOneLiner(fesNone) == ""

    # And the recipe that carries it is one statement inside one `devEnv:`.
    let recipe = synthesizedProjectFileText(fesFlake)
    var devEnvIndex = -1
    var lines: seq[string] = @[]
    for line in recipe.splitLines():
      lines.add(line)
    for i, line in lines:
      if line.strip() == "devEnv:":
        devEnvIndex = i
    check devEnvIndex >= 0
    var bodyLines: seq[string] = @[]
    for i in devEnvIndex + 1 ..< lines.len:
      if lines[i].strip().len > 0:
        bodyLines.add(lines[i].strip())
    check bodyLines == @[oneLiner]

    # A recipe that names no import cannot compile, so the generated text has
    # to carry the stdlib import that supplies the one-liner. Asserting it
    # here is what stops the "one line" claim from being true only because
    # the generated file was never made to work.
    check recipe.contains("import repro_dsl_stdlib/foreign_env")
    check recipe.contains("package " & SynthesizedPackageName & ":")

  test "the_flake_command_is_the_one_direnv_already_runs":
    # `nix print-dev-env --profile <profile> '.?submodules=1'
    #  --override-input <name> path:<sibling>` — the live shape from this
    # workspace's `.envrc`. Asserted positionally: `--profile` before the
    # flake expression, every override AFTER it, `path:` prefixed.
    let argv = flakePrintDevEnvArgv("/usr/bin/nix", DefaultFlakeRef,
      "/w/.repro/foreign-env/flake-profile",
      @[("runquota-src", "/w/../runquota"), ("io-mon-src", "/w/../io-mon")])
    check argv == @[
      "/usr/bin/nix", "print-dev-env",
      "--profile", "/w/.repro/foreign-env/flake-profile",
      ".?submodules=1",
      "--override-input", "runquota-src", "path:/w/../runquota",
      "--override-input", "io-mon-src", "path:/w/../io-mon"]

    # An empty override list emits no override arguments at all — and an
    # override with a missing half is dropped rather than emitted broken,
    # because `nix` would otherwise consume the next argument as the path.
    check flakePrintDevEnvArgv("nix", ".", "") == @["nix", "print-dev-env", "."]
    check flakePrintDevEnvArgv("nix", ".", "", @[("named", "")]) ==
      @["nix", "print-dev-env", "."]

  test "a_foreign_contribution_is_a_diff_not_the_whole_environment":
    # The capture sources a script from a real environment, so most of what
    # comes back is what went in. Only the difference is a contribution.
    let baseline = @[
      ("PATH", "/usr/bin:/bin"),
      ("HOME", "/home/dev"),
      ("XDG_DATA_DIRS", "/usr/share"),
      ("STALE", "gone"),
      ("PWD", "/somewhere")]
    let captured = @[
      ("PATH", "/nix/store/aa/bin:/nix/store/bb/bin:/usr/bin:/bin"),
      ("HOME", "/home/dev"),
      ("XDG_DATA_DIRS", "/usr/share:/nix/store/cc/share"),
      ("NEW_VAR", "hello"),
      ("PWD", "/elsewhere")]
    let ops = foreignEnvOpsFromDump(baseline, captured, ":")

    # PATH survived verbatim at the tail, so the head is a PREPEND, not a set
    # that bakes `/usr/bin:/bin` into a cached artifact.
    check opFor(ops, "PATH", feoPrepend).value ==
      "/nix/store/aa/bin:/nix/store/bb/bin"
    check not ops.hasOpKind("PATH", feoSet)
    # The baseline survived at the head, so the tail is an APPEND.
    check opFor(ops, "XDG_DATA_DIRS", feoAppend).value ==
      "/nix/store/cc/share"
    # Genuinely new, genuinely gone.
    check opFor(ops, "NEW_VAR", feoSet).value == "hello"
    check opFor(ops, "STALE", feoUnset).name == "STALE"
    # Unchanged and shell bookkeeping contribute nothing.
    check not ops.hasOpFor("HOME")
    check not ops.hasOpFor("PWD")

    # Deterministic ordering: `env` promises none, and an artifact whose bytes
    # depend on environ order would never cache-hit.
    var names: seq[string] = @[]
    for op in ops:
      names.add(op.name)
    var sorted = names
    sorted.sort()
    check names == sorted

  test "a_nul_delimited_dump_survives_a_multi_line_value":
    # A `shellHook` may export a multi-line value. A newline-delimited dump
    # would truncate it and then silently disagree with `nix develop`.
    let dumped = parseNulEnvDump("A=one\ntwo\x00B=three\x00")
    check dumped == @[("A", "one\ntwo"), ("B", "three")]
    check parseNulEnvDump("=novalue\x00OK=1\x00") == @[("OK", "1")]

  test "repro_nim_trumps_envrc_which_trumps_flake_nix":
    # The precedence rule, exhaustively, with BOTH flags on so the only thing
    # deciding the answer is what is on disk.
    let both = ForeignEnvAutoLoad(envrc: true, flake: true)
    check chooseForeignEnvSource(hasProjectFile = true, hasEnvrc = true,
      hasFlake = true, both) == fesNone
    check chooseForeignEnvSource(hasProjectFile = false, hasEnvrc = true,
      hasFlake = true, both) == fesEnvrc
    check chooseForeignEnvSource(hasProjectFile = false, hasEnvrc = false,
      hasFlake = true, both) == fesFlake
    check chooseForeignEnvSource(hasProjectFile = false, hasEnvrc = false,
      hasFlake = false, both) == fesNone

    # And against the real filesystem, including the legacy project-file name.
    let root = createTempDir("repro-nf4-precedence", "")
    defer: removeDir(root)
    writeFile(root / "flake.nix", "{ outputs = _: {}; }\n")
    check detectForeignEnvSource(root, both) == fesFlake
    writeFile(root / ".envrc", "use flake\n")
    check detectForeignEnvSource(root, both) == fesEnvrc
    writeFile(root / "reprobuild.nim", "package p:\n  discard\n")
    check detectForeignEnvSource(root, both) == fesNone
    removeFile(root / "reprobuild.nim")
    writeFile(root / "repro.nim", "package p:\n  discard\n")
    check detectForeignEnvSource(root, both) == fesNone

  test "the_two_auto_load_flags_are_independent":
    # Two flags, not one tri-state: each source can be enabled without the
    # other, and a disabled source is never reached even when its file is the
    # only one present.
    let root = createTempDir("repro-nf4-flags", "")
    defer: removeDir(root)
    writeFile(root / "flake.nix", "{ outputs = _: {}; }\n")
    writeFile(root / ".envrc", "use flake\n")

    let flakeOnly = ForeignEnvAutoLoad(envrc: false, flake: true)
    let envrcOnly = ForeignEnvAutoLoad(envrc: true, flake: false)
    let neither = ForeignEnvAutoLoad(envrc: false, flake: false)

    # `.envrc` wins when both are enabled; with only the flake flag on, the
    # present `.envrc` is skipped rather than silently promoted.
    check detectForeignEnvSource(root, flakeOnly) == fesFlake
    check detectForeignEnvSource(root, envrcOnly) == fesEnvrc
    check detectForeignEnvSource(root, neither) == fesNone

  test "the_synthesised_recipe_is_written_once_and_not_churned":
    # The provider compile is keyed on this file. Rewriting it on every shell
    # entry would rebuild the provider on every prompt, which is the cost NF-4
    # exists to avoid paying twice.
    let root = createTempDir("repro-nf4-synth", "")
    defer: removeDir(root)
    let first = ensureSynthesizedProjectFile(root, fesFlake)
    check first == synthesizedProjectFilePath(root)
    check first.startsWith(root / ".repro")
    check fileExists(first)
    let bytes = readFile(first)
    check bytes.contains("useFlakeDevShell()")
    let stampBefore = getLastModificationTime(first)
    sleep(1100)
    let second = ensureSynthesizedProjectFile(root, fesFlake)
    check second == first
    check readFile(second) == bytes
    check getLastModificationTime(second) == stampBefore

    # A changed decision DOES rewrite it.
    let third = ensureSynthesizedProjectFile(root, fesEnvrc)
    check readFile(third).contains("useEnvrc()")
    check not readFile(third).contains("useFlakeDevShell()")

    # Nothing to synthesise is the empty string and no file write.
    let bare = createTempDir("repro-nf4-synth-none", "")
    defer: removeDir(bare)
    check ensureSynthesizedProjectFile(bare, fesNone) == ""
    check not fileExists(synthesizedProjectFilePath(bare))

  test "the_synthesised_recipe_is_in_the_prompt_time_cache_key":
    # `computeDevEnvEdgeCacheKey` is what the shell hook's per-prompt fast path
    # asks BEFORE walking the build graph: same key, same environment, emit a
    # no-op. For a project with no `repro.nim` of its own the synthesised
    # recipe is the only thing that says WHICH foreign environment is
    # activated, so leaving it out of the key would let an operator flip
    # auto-load from `.envrc` to `flake.nix` and keep being handed the
    # environment they just turned off.
    let root = createTempDir("repro-nf4-key", "")
    defer: removeDir(root)
    let bare = computeDevEnvEdgeCacheKey(root, "default", "", "")

    discard ensureSynthesizedProjectFile(root, fesFlake)
    let flakeKey = computeDevEnvEdgeCacheKey(root, "default", "", "")
    check flakeKey != bare

    discard ensureSynthesizedProjectFile(root, fesEnvrc)
    let envrcKey = computeDevEnvEdgeCacheKey(root, "default", "", "")
    check envrcKey != flakeKey
    check envrcKey != bare

    # And it is the same key twice for the same decision — a key that moved on
    # its own would make the fast path miss on every prompt, which is the cost
    # the fast path exists to avoid.
    discard ensureSynthesizedProjectFile(root, fesEnvrc)
    check computeDevEnvEdgeCacheKey(root, "default", "", "") == envrcKey

    # A project file of the project's OWN still wins: auto-load never governs
    # a directory whose recipe is written by a person.
    writeFile(root / "repro.nim", "package p:\n  discard\n")
    check computeDevEnvEdgeCacheKey(root, "default", "", "") != envrcKey

  test "only_nix_s_own_derived_state_stops_being_an_observed_input":
    # NF-4 widens ONE thing in the engine: the set of paths the dev-env
    # introspection edge's monitor must not record as inputs. Every entry in
    # that set is a licence for a cached dev shell to survive a change it was
    # actually built from, so the set is asserted rather than described.
    #
    # What has to be there was MEASURED, from the `.iomon` of a real
    # `useFlakeDevShell()` edge on this host: `nix` opens
    # `~/.cache/nix/eval-cache-v6/*` and `~/.cache/nix/fetcher-cache-v4.sqlite`
    # (plus its `-shm`/`-wal` companions) read-write on every invocation, so
    # without this every shell entry would invalidate the previous one and the
    # cached artifact would never be reused once.
    #
    # What must NOT be there is the point of the case. Reprobuild's OWN
    # content-addressed store and action cache live under the same user cache
    # directory — `repro_local_store.defaultUserStoreRoot()` is
    # `$XDG_CACHE_HOME/repro/store` and the action cache is its sibling
    # `repro/action-cache` — so ignoring the user cache directory WHOLESALE
    # would make this edge blind to the artifacts Reprobuild itself
    # materialises for it. That is not a foreign tool's private scratch; it is
    # the store, it is content-addressed, and it IS reproducible on another
    # machine, so the usual "you had lost that guarantee anyway" defence of a
    # broad ignore does not apply to it.
    let project = createTempDir("repro-nf4-ignored", "")
    defer: removeDir(project)
    let ignored = devEnvIntrospectionIgnoredInputPrefixes(project)

    proc isIgnored(path: string): bool =
      let normalized = path.replace('\\', '/')
      for prefix in ignored:
        let root = prefix.replace('\\', '/')
        if normalized == root or normalized.startsWith(root & "/"):
          return true
      false

    # The edge's own scratch — the produced script, the profile gcroot, the
    # two stdout/stderr side channels — is written and read back by the edge.
    check isIgnored(flakeForeignEnvWorkDir(project) / "print-dev-env.bash")
    check isIgnored(envrcForeignEnvWorkDir(project) / "direnv-export.bash")
    # …and only under THIS project. A sibling project's scratch is somebody
    # else's state, not derived state of this edge.
    check not isIgnored(parentDir(project) / "other-project" / ".repro" /
      "foreign-env" / "print-dev-env.bash")

    # `nix`'s own memory of its past runs, resolved the way `nix` resolves it.
    let nixCache =
      if getEnv("XDG_CACHE_HOME").len > 0: getEnv("XDG_CACHE_HOME") / "nix"
      else: getEnv("HOME") / ".cache" / "nix"
    check isIgnored(nixCache / "eval-cache-v6" / "abc.sqlite")
    check isIgnored(nixCache / "fetcher-cache-v4.sqlite-wal")

    # Reprobuild's own store and action cache are NOT foreign scratch.
    let storeRoot = defaultUserStoreRoot()
    check not isIgnored(storeRoot / "cas" / "ab" / "blob")
    check not isIgnored(parentDir(storeRoot) / "action-cache" / "entry")

    # Nor is anything else a dev environment is genuinely built from. Both of
    # these were OBSERVED in the same depfile as the two caches above, which is
    # what makes them the sharp cases: a `nix.conf` decides what `nix` even
    # does, and the one under the user's nix PROFILE lives beneath the user
    # STATE directory — so a `~/.local/state` prefix would drop a real input
    # while ignoring nothing that churns.
    check not isIgnored(getEnv("HOME") / ".local" / "state" / "nix" /
      "profile" / "etc" / "xdg" / "nix" / "nix.conf")
    check not isIgnored(getConfigDir() / "nix" / "nix.conf")

  test "activating_an_envrc_absorbs_what_direnv_exports":
    # The `.envrc` half of NF-4, against a real `direnv`. `direnv` is a hard
    # requirement of this gate for the same reason `nix` is a hard requirement
    # of the flake gate (and the same reason M5's direnv gate states): a gate
    # whose subject is a foreign tool is worthless if the tool's absence reads
    # as success.
    let direnv = findExe("direnv")
    require direnv.len > 0
    checkpoint "using direnv at " & direnv

    let root = createTempDir("repro-nf4-envrc", "")
    defer: removeDir(root)
    let project = root / "project"
    createDir(project)
    createDir(project / "tools" / "bin")
    writeFile(project / ".envrc",
      "export NF4_ENVRC_VAR=envrc-value\n" &
      "PATH_add \"$PWD/tools/bin\"\n")

    # direnv's authorization database is keyed on `XDG_DATA_HOME`; pointing it
    # at the temp tree keeps `direnv allow` from writing into the developer's
    # own allow list for a directory that is about to be deleted.
    let previousDataHome =
      if existsEnv("XDG_DATA_HOME"): getEnv("XDG_DATA_HOME") else: ""
    putEnv("XDG_DATA_HOME", root / "xdg-data")
    defer:
      if previousDataHome.len > 0: putEnv("XDG_DATA_HOME", previousDataHome)
      else: delEnv("XDG_DATA_HOME")

    var allow = startProcess(direnv, project, ["allow", "."], nil, {})
    let allowed = allow.waitForExit()
    allow.close()
    check allowed == 0

    let ops = envrcOps(project, direnv)
    check opFor(ops, "NF4_ENVRC_VAR", feoSet).value == "envrc-value"
    # `PATH_add` prepends, and the capture must report it AS a prepend: a
    # `setEnv` here would bake the capturing process's whole `PATH` into the
    # artifact and then replay it in an unrelated shell.
    check opFor(ops, "PATH", feoPrepend).value == project / "tools" / "bin"
    check not ops.hasOpKind("PATH", feoSet)
    # direnv's own state describes direnv, not the project.
    for op in ops:
      check not op.name.startsWith(DirenvBookkeepingPrefix)
    # The transient script direnv produced is kept, where the stdlib says.
    check fileExists(envrcForeignEnvWorkDir(project) / "direnv-export.bash")
