## HLX-M1 verification gate `integration_hcr_linux_elf_symbol_resolution`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §7.1, §7.2, §7.5.
##
## `allowed_mocks: none`. Real GCC invocations; real PIE, non-PIE and stripped
## executables; a real shared library linked normally (no `dlopen`); real
## `dl_iterate_phdr` inside a real running process; real on-disk `.symtab` and
## `.dynsym`; and the PRODUCTION resolver header compiled straight into the
## fixture, not a reimplementation of it.
##
## The observable is not the resolver's opinion of itself. For every symbol the
## fixture prints BOTH the address the resolver computed AND the address the
## process reports for the same function through `&fn`, and this gate asserts
## they are equal. Design §7.2's `dlpi_addr + st_value` is the single most
## common source of "patched the wrong address", and a resolver that returns a
## confident wrong number fails here rather than silently later.
##
## What each arm establishes:
##
##   * PIE — a non-zero `dlpi_addr` for both the executable and the shared
##     library, and two DIFFERENT biases in one process, so a resolver that
##     used the wrong object's bias could not pass.
##   * non-PIE — `dlpi_addr` is 0 for the main executable and the same formula
##     still holds, which is the case design §7.2 step 1 calls out explicitly.
##   * stripped + `-rdynamic` — `.symtab` removed with real `strip`, so the
##     `.dynsym` fallback of design §7.2 step 3 is the live path. The exported
##     symbol still resolves; the `static` one is genuinely unreachable there
##     and is REFUSED by name rather than answered wrongly.
##   * stripped WITHOUT `-rdynamic` — the standing capability limit, asserted
##     so it cannot quietly change. An ordinary release executable puts none of
##     its own functions in `.dynsym`, so after stripping NOTHING in it is
##     resolvable and every class is refused. Measured on the real 84 MB Godot
##     build: 771 `.dynsym` records for a binary with well over a hundred
##     thousand functions, and `main` is not among them. The unstripped shared
##     library in the same process still resolves, which is what makes this an
##     assertion about `.dynsym` rather than about a broken resolver.
##   * `static` and hidden functions resolve at all, which is the entire point
##     of design §7.1: `dlsym` cannot see either, and the gate proves the
##     binary contains no `dlsym` call to fall back on.
##   * `STT_GNU_IFUNC` is refused, and the gate asserts the refused `st_value`
##     is the RESOLVER's address, not the implementation's — i.e. that patching
##     it would genuinely have hit the wrong function.
##   * Symbol versioning: names DISCOVERED from the libc this process actually
##     loads (never hard-coded — which symbols glibc versions changes between
##     releases), each carrying both a default `@@` and a compatibility `@`
##     entry. The resolver must pick the default one, and the gate asserts its
##     `st_value` equals the one `readelf` attributes to the `@@` entry. This
##     is the `.dynsym` path, where the version is out of band in
##     `.gnu.version` and stripping an `@@` suffix from the name would find
##     nothing to strip.
##   * Three ways to be absent stay distinct: a name that is a global VARIABLE
##     (`elf-symbol-not-a-function`), a name present only as an UNDEFINED
##     import when the search is confined to one object (`elf-symbol-undefined`),
##     and a name that is nowhere (`elf-symbol-not-found`). These are three
##     different mistakes on the caller's part, and one refusal for all three
##     would send whoever is debugging a failed patch hunting a typo that is
##     not there.
##
## No silent skips: a missing compiler or a missing fixture fails loudly.

import std/[json, os, osproc, strutils, unittest]

when defined(linux) and defined(amd64):

  type ResolveRecord = object
    label: string
    symbol: string
    refusalName: string
    refusal: int
    resolvedAddress: uint64
    truthAddress: uint64
    matchCount: int
    objectsSeen: int
    objectsParsed: int
    objectsRefused: int
    objectsSkipped: int
    symbolsScanned: uint64
    loadBias: uint64
    linkValue: uint64
    symbolSize: uint64
    fromDynsym: int
    sourceFile: string
    objectPath: string
    sectionName: string
    version: string
    defaultVersion: int
    detail: string

  type ProbeRun = object
    variant: string
    binaryPath: string
    ifuncResolverAddress: uint64
    ifuncImplementationAddress: uint64
    records: seq[ResolveRecord]
    raw: JsonNode

  proc q(value: string): string = quoteShell(value)

  proc shellCommand(args: openArray[string]): string =
    for index, arg in args:
      if index > 0:
        result.add(" ")
      result.add(q(arg))

  proc runSuccess(command: string; cwd: string): string =
    let res = execCmdEx(command, workingDir = cwd)
    if res.exitCode != 0:
      checkpoint("command failed (exit " & $res.exitCode & "): " & command)
      checkpoint(res.output)
    require res.exitCode == 0
    res.output

  proc requireTool(name: string) =
    let found = findExe(name)
    if found.len == 0:
      checkpoint("required tool is not on PATH: " & name)
    require found.len > 0

  proc requireFixture(path: string) =
    if not fileExists(path):
      checkpoint("fixture source is missing: " & path)
    require fileExists(path)

  proc recordOf(node: JsonNode): ResolveRecord =
    ResolveRecord(
      label: node["label"].getStr(),
      symbol: node["symbol"].getStr(),
      refusalName: node["refusalName"].getStr(),
      refusal: node["refusal"].getInt(),
      resolvedAddress: uint64(node["resolvedAddress"].getBiggestInt()),
      truthAddress: uint64(node["truthAddress"].getBiggestInt()),
      matchCount: node["matchCount"].getInt(),
      objectsSeen: node["objectsSeen"].getInt(),
      objectsParsed: node["objectsParsed"].getInt(),
      objectsRefused: node["objectsRefused"].getInt(),
      objectsSkipped: node["objectsSkipped"].getInt(),
      symbolsScanned: uint64(node["symbolsScanned"].getBiggestInt()),
      loadBias: uint64(node["loadBias"].getBiggestInt()),
      linkValue: uint64(node["linkValue"].getBiggestInt()),
      symbolSize: uint64(node["symbolSize"].getBiggestInt()),
      fromDynsym: node["fromDynsym"].getInt(),
      sourceFile: node["sourceFile"].getStr(),
      objectPath: node["objectPath"].getStr(),
      sectionName: node["sectionName"].getStr(),
      version: node["version"].getStr(),
      defaultVersion: node["defaultVersion"].getInt(),
      detail: node["detail"].getStr())

  proc find(run: ProbeRun; label: string): ResolveRecord =
    for record in run.records:
      if record.label == label:
        return record
    checkpoint("probe run \"" & run.variant &
      "\" produced no record labelled \"" & label &
      "\"; the fixture and this gate have drifted apart")
    fail()

  suite "integration_hcr_linux_elf_symbol_resolution":
    test "static, hidden and exported functions resolve to their real runtime addresses":
      requireTool("gcc")
      requireTool("strip")
      requireTool("nm")
      requireTool("readelf")

      let repoRoot = getCurrentDir()
      let fixtureDir = repoRoot / "tests" / "fixtures" / "hcr" /
        "linux-elf-symbols"
      let probeSource = fixtureDir / "hcr_lx_elf_probe.c"
      let libSource = fixtureDir / "hcr_lx_elf_lib.c"
      requireFixture(probeSource)
      requireFixture(libSource)

      let agentInclude = repoRoot / "libs" / "repro_hcr_agent" / "c"
      requireFixture(agentInclude / "repro_hcr_linux_elf_symbols.h")

      let workDir = repoRoot / "build" / "hcr-linux-elf-symbols"
      removeDir(workDir)
      createDir(workDir)

      # `--build-id` is not the default on every toolchain — measured, the GCC
      # in this dev shell emits none unless asked — and design §7.3 makes the
      # check mandatory, so the fixture link asks for it explicitly. That is
      # the same requirement HLX-M1 adds to the patchable link profile.
      let libPath = workDir / "libhcrlxelffixture.so"
      discard runSuccess(shellCommand(["gcc", "-O2", "-g", "-fPIC", "-shared",
        "-Wl,--build-id=sha1", "-I" & fixtureDir, libSource, "-o", libPath]),
        repoRoot)

      proc buildProbe(variant: string; extra: openArray[string]): string =
        let outPath = workDir / ("probe-" & variant)
        var args = @["gcc", "-O2", "-g", "-Wl,--build-id=sha1",
                     "-I" & fixtureDir, "-I" & agentInclude]
        for flag in extra:
          args.add flag
        args.add probeSource
        args.add "-o"
        args.add outPath
        args.add "-L" & workDir
        args.add "-lhcrlxelffixture"
        args.add "-Wl,-rpath," & workDir
        discard runSuccess(shellCommand(args), repoRoot)
        outPath

      proc runProbe(variant, binaryPath: string;
                    versionedNames: openArray[string] = []): ProbeRun =
        var command = q(binaryPath)
        for name in versionedNames:
          command.add " " & q(name)
        let output = runSuccess(command, repoRoot).strip()
        let parsed =
          try:
            parseJson(output)
          except CatchableError as err:
            # Trap 9: a probe that swallows its own failure into an empty
            # result makes "the fixture crashed" and "there is nothing to
            # report" identical. Neither is allowed to pass quietly.
            checkpoint("probe \"" & variant & "\" did not emit parseable JSON: " &
              err.msg)
            checkpoint(output)
            fail()
            newJObject()
        check parsed["schemaId"].getStr() ==
          "reprobuild.hcr.hlx-m1.elf-symbol-resolution.v1"
        result.variant = variant
        result.binaryPath = binaryPath
        result.raw = parsed
        result.ifuncResolverAddress =
          uint64(parsed["ifuncResolverAddress"].getBiggestInt())
        result.ifuncImplementationAddress =
          uint64(parsed["ifuncImplementationAddress"].getBiggestInt())
        for node in parsed["records"]:
          result.records.add recordOf(node)
        # A run that produced no records at all is a broken fixture, not a
        # clean result.
        check result.records.len == 10 + versionedNames.len

      let piePath = buildProbe("pie", ["-fPIE", "-pie"])
      let nonPiePath = buildProbe("nopie", ["-fno-pie", "-no-pie"])
      # `-rdynamic` puts the executable's global functions into `.dynsym`.
      # Without it a stripped executable has no usable symbol table AT ALL,
      # which is a real capability limit and is asserted separately below.
      let rdynamicPath = buildProbe("rdynamic", ["-fPIE", "-pie", "-rdynamic"])

      proc stripCopy(sourcePath, variant: string): string =
        result = workDir / ("probe-" & variant)
        # With permissions: a plain `copyFile` drops the execute bit and the
        # stripped arm would fail with exit 126 rather than running.
        copyFileWithPermissions(sourcePath, result)
        discard runSuccess(shellCommand(["strip", "--strip-all", result]),
          repoRoot)
        check runSuccess(shellCommand(["readelf", "-SW", sourcePath]), repoRoot)
          .contains(".symtab")
        # If `strip` left `.symtab` in place the arm proves nothing, so the
        # precondition is asserted rather than assumed.
        check not runSuccess(shellCommand(["readelf", "-SW", result]),
          repoRoot).contains(".symtab")

      let strippedPath = stripCopy(piePath, "stripped")
      let strippedRdynamicPath = stripCopy(rdynamicPath, "stripped-rdynamic")

      # -------------------------------------------------------------------
      # Symbol versioning (design §7.2 step 4). The names are DISCOVERED from
      # the libc this process actually loads, not hard-coded, because which
      # symbols glibc versions changes between releases. A host where none
      # exists fails the gate rather than skipping it: glibc always has them,
      # so an empty result means the discovery is broken, not that the feature
      # is untestable here.
      # -------------------------------------------------------------------
      var libcPath = ""
      for line in runSuccess(shellCommand(["ldd", piePath]), repoRoot)
          .splitLines():
        if line.contains("libc.so.6") and line.contains("=>"):
          let rhs = line.split("=>")[1].strip()
          libcPath = rhs.split(" (")[0].strip()
      if libcPath.len == 0 or not fileExists(libcPath):
        checkpoint("could not locate libc.so.6 for the probe binary; the " &
          "symbol-versioning arm cannot run")
      require libcPath.len > 0
      require fileExists(libcPath)

      # A base name qualifies only if libc exports it BOTH as `name@@V`
      # (default) and as `name@V2` (a compatibility alias). That pairing is
      # precisely what the default-version selection has to get right.
      var defaultVersioned: seq[string] = @[]
      var compatVersioned: seq[string] = @[]
      for line in runSuccess(shellCommand(["readelf", "-sW", "--dyn-syms",
          libcPath]), repoRoot).splitLines():
        let fields = line.splitWhitespace()
        if fields.len < 8 or fields[3] != "FUNC" or fields[6] == "UND":
          continue
        let raw = fields[7]
        if not raw.contains("@"):
          continue
        let base = raw.split("@")[0]
        if raw.contains("@@"):
          if base notin defaultVersioned: defaultVersioned.add base
        else:
          if base notin compatVersioned: compatVersioned.add base
      var versionedNames: seq[string] = @[]
      for name in defaultVersioned:
        if name in compatVersioned and versionedNames.len < 3:
          versionedNames.add name
      if versionedNames.len == 0:
        checkpoint("no libc symbol carries both a default (@@) and a " &
          "compatibility (@) version; the versioning arm would prove nothing")
      require versionedNames.len > 0

      let pie = runProbe("pie", piePath, versionedNames)
      let nonPie = runProbe("nopie", nonPiePath)
      let stripped = runProbe("stripped", strippedPath)
      let strippedRdynamic = runProbe("stripped-rdynamic", strippedRdynamicPath)

      # ---------------------------------------------------------------------
      # Design §7.1 — there is no `dlsym` to fall back on. If there were, the
      # exported cases could pass while the resolver was broken.
      # ---------------------------------------------------------------------
      for path in [piePath, nonPiePath]:
        let undefined = runSuccess(shellCommand(["nm", "-u", path]), repoRoot)
        # Review 2026-09-10: the two negatives below are only worth anything if
        # the scan produced something to search. An empty `nm -u` would satisfy
        # them for free and this arm — the one that establishes design §7.1's
        # central claim — would pass vacuously. `dl_iterate_phdr` is the symbol
        # the resolver genuinely imports, so its presence is the positive
        # control that proves the listing is real.
        check undefined.contains("dl_iterate_phdr")
        check not undefined.contains("dlsym")
        check not undefined.contains("dlopen")

      # ---------------------------------------------------------------------
      # PIE: every class resolves, and the resolved address is the address the
      # process itself reports.
      # ---------------------------------------------------------------------
      const ResolvableLabels = ["exe-static", "exe-hidden", "exe-exported",
                                "lib-static", "lib-hidden", "lib-exported"]
      for label in ResolvableLabels:
        let record = pie.find(label)
        checkpoint("PIE " & label & ": " & record.detail)
        check record.refusalName == "ok"
        check record.matchCount == 1
        check record.truthAddress != 0'u64
        check record.resolvedAddress == record.truthAddress
        # Design §7.2 step 1, spelled out: the answer really is bias + st_value.
        check record.loadBias + record.linkValue == record.truthAddress
        check record.symbolSize > 0'u64   # §7.5: st_size is authoritative
        check record.fromDynsym == 0      # §7.2 step 3 prefers .symtab
        check record.sectionName == ".text"
        # The vDSO has no file behind it and is skipped explicitly, so a
        # failure to open it can never be mistaken for a real object failing.
        check record.objectsSkipped >= 1
        check record.objectsRefused == 0
        check record.objectsParsed >= 2
        check record.symbolsScanned > 0'u64

      # Two DIFFERENT non-zero biases in one process. A resolver that applied
      # the main executable's bias to the library's symbols would land in
      # unmapped memory, and this is what makes that impossible to pass.
      let pieExeBias = pie.find("exe-static").loadBias
      let pieLibBias = pie.find("lib-static").loadBias
      check pieExeBias != 0'u64
      check pieLibBias != 0'u64
      check pieExeBias != pieLibBias
      check pie.find("exe-static").objectPath.endsWith("probe-pie")
      check pie.find("lib-static").objectPath.endsWith("libhcrlxelffixture.so")

      # `static` functions carry their defining translation unit (the measured
      # correction to design §7.4 — see the ambiguity gate).
      check pie.find("exe-static").sourceFile == "hcr_lx_elf_probe.c"
      check pie.find("lib-static").sourceFile == "hcr_lx_elf_lib.c"

      # ---------------------------------------------------------------------
      # non-PIE: `dlpi_addr` is 0 for the main executable and the formula still
      # holds (design §7.2 step 1). The shared library still has a real bias.
      # ---------------------------------------------------------------------
      for label in ["exe-static", "exe-hidden", "exe-exported"]:
        let record = nonPie.find(label)
        checkpoint("non-PIE " & label & ": " & record.detail)
        check record.refusalName == "ok"
        check record.loadBias == 0'u64
        check record.resolvedAddress == record.truthAddress
        check record.linkValue == record.truthAddress
      check nonPie.find("lib-static").loadBias != 0'u64
      check nonPie.find("lib-static").resolvedAddress ==
        nonPie.find("lib-static").truthAddress

      # ---------------------------------------------------------------------
      # `STT_GNU_IFUNC` (design §7.2 step 5). Refused — and the point is not
      # merely that it was refused, but that the address it WOULD have used is
      # the resolver's rather than the implementation's.
      # ---------------------------------------------------------------------
      for run in [pie, nonPie]:
        let record = run.find("exe-ifunc")
        checkpoint(run.variant & " ifunc: " & record.detail)
        check record.refusalName == "elf-symbol-is-ifunc"
        check record.resolvedAddress == 0'u64
        check record.detail.contains("resolver, not its implementation")
        # st_value points at the resolver ...
        check record.loadBias + record.linkValue == run.ifuncResolverAddress
        # ... and the resolver is NOT the implementation, so a provider that
        # trusted st_value would have patched the wrong function.
        check run.ifuncResolverAddress != run.ifuncImplementationAddress
        check record.truthAddress == run.ifuncImplementationAddress

      # ---------------------------------------------------------------------
      # A symbol that is genuinely absent is refused by name, with a diagnostic
      # that says how much was actually read — never an empty answer.
      # ---------------------------------------------------------------------
      let absent = pie.find("absent")
      check absent.refusalName == "elf-symbol-not-found"
      check absent.matchCount == 0
      check absent.detail.len > 0
      check absent.detail.contains("symbol records read")
      check absent.detail.contains("no dlsym fallback")

      # ---------------------------------------------------------------------
      # Stripped binary: the `.dynsym` fallback of design §7.2 step 3.
      #
      # This arm is where a resolver could most easily lie. `.dynsym` holds the
      # exported symbol and NOT the static one, so the honest outcome is one
      # success and one NAMED refusal — not two successes, and not two silent
      # zeroes.
      # ---------------------------------------------------------------------
      # Symbol versioning, asserted against `readelf`'s view of the same libc.
      #
      # `.dynsym` names carry NO version text — the version lives out of band
      # in `.gnu.version`, with the names in `.gnu.version_d`/`.gnu.version_r`.
      # So a resolver that only stripped an `@@` suffix from the name would
      # see N identical `memcpy`s and refuse them all as ambiguous. Getting
      # this right means reading the parallel table and picking the DEFAULT
      # version, and that is what these assertions check.
      # ---------------------------------------------------------------------
      # WHICH of the two version paths runs depends on the library, and both
      # are real: an UNSTRIPPED libc (the nix one here) keeps `.symtab`, where
      # the version is spelled into the name as `name@@V`, while a stripped
      # one leaves only `.dynsym`, where it is out of band. The assertions
      # below hold either way, because they are about the ANSWER — the default
      # version's address and its name — rather than about which table it came
      # from. `fromDynsym` is therefore recorded in the evidence and not
      # asserted; pinning it would make the gate fail on a host whose libc is
      # stripped differently, which is not a property worth being brittle over.
      for name in versionedNames:
        let record = pie.find("versioned-" & name)
        checkpoint("versioned " & name & ": " & record.detail)
        # The default version is selected, so the name is NOT ambiguous even
        # though several `.dynsym` entries share it.
        check record.refusalName == "ok"
        check record.resolvedAddress != 0'u64
        check record.objectPath.contains("libc.so.6")
        # The address and the version NAME are both the ones `readelf`
        # attributes to the `@@` (default) entry — not a compatibility alias,
        # and not nothing.
        var defaultStValue = 0'u64
        var defaultVersion = ""
        for line in runSuccess(shellCommand(["readelf", "-sW", "--dyn-syms",
            libcPath]), repoRoot).splitLines():
          let fields = line.splitWhitespace()
          if fields.len >= 8 and fields[3] == "FUNC" and
              fields[7].startsWith(name & "@@"):
            defaultStValue = uint64(parseHexInt(fields[1]))
            defaultVersion = fields[7].split("@@")[1]
        check defaultStValue != 0'u64
        check defaultVersion.len > 0
        check record.linkValue == defaultStValue
        # Reporting the version at all is the part a bare name-match cannot do.
        check record.version == defaultVersion
        # And it is flagged as the DEFAULT version, which is the bit that
        # decides selection when several entries share the base name.
        check record.defaultVersion == 1

      # ---------------------------------------------------------------------
      # Three ways to be absent, kept distinct. A patch request that names a
      # global variable, one that names a function this object only imports,
      # and one that names nothing at all are three different mistakes, and a
      # single `elf-symbol-not-found` for all three would send whoever is
      # debugging a failed patch looking for a typo that is not there.
      # ---------------------------------------------------------------------
      let variable = pie.find("exe-variable")
      checkpoint("exe-variable: " & variable.detail)
      check variable.refusalName == "elf-symbol-not-a-function"
      check variable.resolvedAddress == 0'u64
      check variable.detail.contains("not a function")

      let imported = pie.find("exe-import")
      checkpoint("exe-import: " & imported.detail)
      check imported.refusalName == "elf-symbol-undefined"
      check imported.resolvedAddress == 0'u64
      check imported.detail.contains("UNDEFINED")
      # The SAME name resolves fine when the search is not confined to the
      # main executable, which is what makes this a statement about where the
      # definition lives rather than about a broken lookup.
      check pie.find("lib-exported").refusalName == "ok"

      # ---------------------------------------------------------------------
      # `-rdynamic` + stripped: `.dynsym` holds the exported function, so the
      # fallback has something to fall back TO. This is the arm that proves
      # design §7.2 step 3's `.dynsym` path works.
      let dynExported = strippedRdynamic.find("exe-exported")
      checkpoint("stripped -rdynamic exe-exported: " & dynExported.detail)
      check dynExported.refusalName == "ok"
      check dynExported.fromDynsym == 1
      check dynExported.resolvedAddress == dynExported.truthAddress
      check dynExported.loadBias + dynExported.linkValue ==
        dynExported.truthAddress
      # The library's exported function also comes from `.dynsym` here only if
      # the library were stripped; it is not, so it must still come from
      # `.symtab`. Asserting the difference keeps the two paths distinguishable.
      check strippedRdynamic.find("lib-exported").fromDynsym == 0

      let dynStatic = strippedRdynamic.find("exe-static")
      checkpoint("stripped -rdynamic exe-static: " & dynStatic.detail)
      check dynStatic.refusalName == "elf-symbol-not-found"
      check dynStatic.resolvedAddress == 0'u64
      check dynStatic.matchCount == 0
      # Refused because a `static` function is not in `.dynsym` — and the
      # diagnostic says so by reporting a real, non-zero volume actually read,
      # rather than an empty answer.
      check dynStatic.symbolsScanned > 0'u64

      # ---------------------------------------------------------------------
      # Stripped WITHOUT `-rdynamic`: the standing capability limit, recorded
      # as an assertion so it cannot quietly change.
      #
      # An ordinary release executable is linked without `-rdynamic` and
      # stripped. Its `.dynsym` then contains only the symbols the dynamic
      # loader needs — imports — and NONE of its own functions. Measured on the
      # real 84 MB Godot build: 771 `.dynsym` records for a binary with well
      # over a hundred thousand functions, and `main` is not among them.
      #
      # So nothing in such a binary is patchable, and the honest report is a
      # named refusal for EVERY class, including the exported one. A resolver
      # that appeared to succeed here would be inventing an address.
      # ---------------------------------------------------------------------
      for label in ["exe-static", "exe-hidden", "exe-exported"]:
        let record = stripped.find(label)
        checkpoint("stripped (no -rdynamic) " & label & ": " & record.detail)
        check record.refusalName == "elf-symbol-not-found"
        check record.resolvedAddress == 0'u64
        check record.detail.len > 0
        check record.detail.contains("symbol records read")
      # It is the executable that lost its symbols, not the whole process: the
      # unstripped shared library still resolves, which is what makes the arm
      # above a statement about `.dynsym` rather than about a broken resolver.
      check stripped.find("lib-static").refusalName == "ok"
      check stripped.find("lib-static").resolvedAddress ==
        stripped.find("lib-static").truthAddress

      # Stripping really did reduce what is visible; if these were equal the
      # arms above would be vacuous.
      check stripped.find("lib-static").symbolsScanned <
        pie.find("lib-static").symbolsScanned

      # ---------------------------------------------------------------------
      # Review 2026-09-10 — "could not read the table" must never surface as
      # "the symbol is not in the table".
      #
      # This arm exists because the C resolver DID have that defect. Three
      # paths in `repro_hcr_elf_scan_symbol_table` returned early without
      # recording a refusal, while the caller had already counted the object as
      # successfully parsed. The result was `elf-symbol-not-found` for a
      # perfectly present symbol whose table the reader could not open — the
      # vacuous-check pattern of Verification-Harness-Traps.md §9, and the
      # third time this campaign has hit it.
      #
      # The corruption is applied to a REAL library that resolves correctly
      # first, so every refusal below is attributable to the byte that was
      # changed and to nothing else.
      # ---------------------------------------------------------------------
      proc u16At(data: string; at: int): int =
        int(uint8(data[at])) or (int(uint8(data[at + 1])) shl 8)

      proc u32At(data: string; at: int): uint32 =
        var value = 0'u32
        for i in countdown(3, 0):
          value = (value shl 8) or uint32(uint8(data[at + i]))
        value

      proc u64At(data: string; at: int): uint64 =
        var value = 0'u64
        for i in countdown(7, 0):
          value = (value shl 8) or uint64(uint8(data[at + i]))
        value

      proc setU32(data: var string; at: int; value: uint32) =
        for i in 0 .. 3:
          data[at + i] = char(uint8((value shr (8 * i)) and 0xff'u32))

      proc setU64(data: var string; at: int; value: uint64) =
        for i in 0 .. 7:
          data[at + i] = char(uint8((value shr (8 * i)) and 0xff'u64))

      # ELF64: e_shoff@40, e_shentsize@58, e_shnum@60. Section header is 64
      # bytes: sh_type@4, sh_offset@24, sh_size@32, sh_link@40, sh_entsize@56.
      const ShtSymtab = 2'u32

      proc symtabHeaderOffset(data: string): int =
        let shoff = int(u64At(data, 40))
        let shentsize = u16At(data, 58)
        let shnum = u16At(data, 60)
        check shentsize == 64
        check shnum > 0
        for i in 0 ..< shnum:
          let hdr = shoff + i * shentsize
          if u32At(data, hdr + 4) == ShtSymtab:
            return hdr
        checkpoint("the fixture library has no SHT_SYMTAB to corrupt; this " &
          "arm cannot establish anything")
        fail()
        -1

      let goodLib = readFile(libPath)
      # The precondition, asserted rather than assumed: the pristine copy has a
      # symbol table and the arm below is really about damaging it.
      let symtabHdr = symtabHeaderOffset(goodLib)
      require symtabHdr > 0

      proc corrupted(variant: string; mutate: proc (data: var string)): string =
        result = workDir / ("corrupt-" & variant & ".so")
        var data = goodLib
        mutate(data)
        check data != goodLib
        writeFile(result, data)

      let badEntsize = corrupted("entsize", proc (data: var string) =
        setU64(data, symtabHdr + 56, 25'u64))
      let badLink = corrupted("link", proc (data: var string) =
        # Point sh_link at section 0, which is never a string table.
        setU32(data, symtabHdr + 40, 0'u32))
      let pastEof = corrupted("past-eof", proc (data: var string) =
        # A symbol table that claims to extend far past the end of the file.
        setU64(data, symtabHdr + 32, 0x0000_0000_4000_0000'u64))
      let shnumOverflow = corrupted("shnum-overflow", proc (data: var string) =
        # `e_shnum == 0` sends the reader to `shdr[0].sh_size` for the real
        # count, and this value makes `count * sizeof(Elf64_Shdr)` wrap to
        # exactly 0 in 64-bit arithmetic. Before the review fix that defeated
        # the bounds check and every later section walk read off the end of the
        # mapping; the gate would crash rather than fail.
        let shoff = int(u64At(data, 40))
        data[60] = '\0'
        data[61] = '\0'
        setU64(data, shoff + 32, 0x0400_0000_0000_0000'u64))

      # `elf-symbol-table-absent`: an object with neither `.symtab` nor
      # `.dynsym`. A stripped relocatable object is exactly that.
      let barePath = workDir / "no-tables.o"
      discard runSuccess(shellCommand(["gcc", "-O2", "-fPIC", "-c",
        "-I" & fixtureDir, libSource, "-o", barePath]), repoRoot)
      discard runSuccess(shellCommand(["strip", "--strip-all", barePath]),
        repoRoot)
      let bareSections = runSuccess(shellCommand(["readelf", "-SW", barePath]),
        repoRoot)
      check not bareSections.contains(".symtab")
      check not bareSections.contains(".dynsym")

      const MalformedSymbol = "hcr_lx_lib_static_helper"
      var inFileArgs = @["--in-file",
        "good", libPath, MalformedSymbol,
        "bad-entsize", badEntsize, MalformedSymbol,
        "bad-link", badLink, MalformedSymbol,
        "past-eof", pastEof, MalformedSymbol,
        "shnum-overflow", shnumOverflow, MalformedSymbol,
        "no-tables", barePath, MalformedSymbol,
        "missing-file", workDir / "there-is-no-such-file.so", MalformedSymbol,
        "empty-symbol", libPath, ""]
      var inFileCommand = q(piePath)
      for arg in inFileArgs:
        inFileCommand.add " " & q(arg)
      let inFileOutput = runSuccess(inFileCommand, repoRoot).strip()
      let inFileParsed = parseJson(inFileOutput)
      var malformed: seq[ResolveRecord] = @[]
      for node in inFileParsed["records"]:
        malformed.add recordOf(node)
      check malformed.len == 8

      proc byLabel(label: string): ResolveRecord =
        for record in malformed:
          if record.label == label:
            return record
        checkpoint("no in-file record labelled \"" & label & "\"")
        fail()

      # The control. The pristine library resolves the symbol, so anything the
      # corrupted copies say is caused by the corruption.
      let goodInFile = byLabel("good")
      checkpoint("in-file good: " & goodInFile.detail)
      check goodInFile.refusalName == "ok"
      check goodInFile.linkValue != 0'u64
      check goodInFile.symbolsScanned > 0'u64
      check goodInFile.objectsParsed == 1
      check goodInFile.objectsRefused == 0

      # The defect itself. Each of these used to answer `elf-symbol-not-found`
      # for a symbol that is demonstrably there — see the control above.
      for label in ["bad-entsize", "bad-link", "past-eof", "shnum-overflow"]:
        let record = byLabel(label)
        checkpoint("in-file " & label & ": " & record.detail)
        check record.refusalName == "elf-object-malformed"
        check record.refusalName != "elf-symbol-not-found"
        check record.resolvedAddress == 0'u64
        check record.objectsRefused == 1
        # A refusal with an empty diagnostic is the same trap wearing a
        # different hat, so the message must name the file and the defect.
        check record.detail.len > 0
        check record.detail.contains("elf-object-malformed")

      # Three more of the declared refusals, which until this arm existed were
      # reachable in principle and asserted nowhere.
      let noTables = byLabel("no-tables")
      checkpoint("in-file no-tables: " & noTables.detail)
      check noTables.refusalName == "elf-symbol-table-absent"
      check noTables.detail.contains(".symtab")

      let missingFile = byLabel("missing-file")
      checkpoint("in-file missing-file: " & missingFile.detail)
      check missingFile.refusalName == "elf-object-unreadable"
      check missingFile.detail.len > 0

      let emptySymbol = byLabel("empty-symbol")
      checkpoint("in-file empty-symbol: " & emptySymbol.detail)
      check emptySymbol.refusalName == "elf-invalid-argument"
      check emptySymbol.detail.len > 0

      # ---------------------------------------------------------------------
      # Evidence.
      # ---------------------------------------------------------------------
      var evidence = newJObject()
      evidence["malformedObjectArm"] = inFileParsed
      evidence["schemaId"] =
        newJString("reprobuild.hcr.hlx-m1.elf-symbol-resolution-gate.v1")
      evidence["gccVersion"] =
        newJString(runSuccess("gcc --version", repoRoot).splitLines()[0])
      evidence["buildIdIsToolchainDefault"] = newJBool(
        runSuccess(shellCommand(["readelf", "-nW", strippedPath]), repoRoot)
          .contains("Build ID"))
      var runs = newJArray()
      for run in [pie, nonPie, stripped, strippedRdynamic]:
        var entry = newJObject()
        entry["variant"] = newJString(run.variant)
        entry["binary"] = newJString(run.binaryPath)
        entry["report"] = run.raw
        runs.add entry
      evidence["runs"] = runs
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "integration_hcr_linux_elf_symbol_resolution.json",
        pretty(evidence))

else:
  suite "integration_hcr_linux_elf_symbol_resolution":
    test "HLX-M1 ELF symbol resolution gate is linux-x86_64-only":
      skip()
