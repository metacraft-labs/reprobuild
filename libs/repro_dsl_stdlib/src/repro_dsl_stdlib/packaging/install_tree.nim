## The DSL packaging layer — the typed *install-tree definition* and the
## §5 runtime-wrapper / RPATH / env-default contract, encoded ONCE.
##
## This is the CPack analog described in
## ``reprobuild-specs/Distribution-And-Packaging.md`` §6: ONE typed
## definition (components + runtime closure + services + metadata) that
## the per-format producers in ``packaging/producers.nim`` translate into
## a ``.deb`` / ``.rpm`` / ``.tar.gz`` (M0) — and, later (M1), into MSI /
## Scoop / .pkg / Homebrew / *BSD / AppImage / Nix, without reshaping this
## core.
##
## ## Why the shape is a plain ``object`` + free ``proc``s, not a macro
##
## The lone pre-existing packaging-output helper —
## ``packages/create_dmg.nim`` — is a thin typed CLI over one backend tool
## (``create-dmg``). It generalises to a *family* the same way the rest of
## the stdlib does: a Layer-1 constructor returns a typed value
## (``Executable`` / ``Library`` carry an ``installPrefix``; here
## ``Distribution`` carries the whole install tree), and downstream
## producers record content-addressed build edges over it (exactly how
## ``constructors/*`` compose ``compile`` / ``link`` edges). The spec's
## illustrative ``package.distribution "x" { ... }`` block-literal is not
## a shape the DSL macros actually expose, so — per the "code wins over
## spec on mechanics" rule — this layer is authored as an ordinary typed
## value + producer procs, callable straight from a recipe ``build:``
## block. (Discrepancy noted for the human: §6's object-literal is
## illustrative only.)
##
## ## The §5 contract lives here, once
##
## ``renderPayloadStaging`` is the single place the runtime-wrapper /
## RPATH / env-default contract is emitted. Every format producer calls
## it to stage an identical *payload tree* (binaries + generated env-seed
## wrappers + vendored runtime libraries with a relocatable RPATH) and
## then only adds format-specific metadata around it. The env-default
## list and the vendored-library closure are DATA on the ``Distribution``
## (``RuntimeContract``), so a caller packaging reprobuild-the-tool passes
## the full ~20 ``REPROBUILD_*`` / ``*_PREFIX`` / ``*_SRC`` defaults plus
## the blake3/xxHash/sqlite/openssl/zstd/clingo closure, while the M0
## two-binary sample passes a trivial closure — the *mechanism* is
## identical either way.

import std/[os, strutils]

import repro_project_dsl
import ../types/executable

export executable

# ---------------------------------------------------------------------------
# The typed install-tree definition
# ---------------------------------------------------------------------------

type
  ServiceScope* = enum
    ## Which of the packaging spec's daemon-role scopes a unit belongs to
    ## (Distribution-And-Packaging.md §4). Only the enum + the abstract
    ## ``ServiceUnit`` live in M0; the per-OS wiring that consumes them
    ## (systemd ``postinst`` enable, launchd plist, Windows service, rc.d)
    ## is authored once in the producers from this abstract list so the
    ## unit is declared a single time regardless of target format.
    ssSystem   ## a system-wide unit (systemd system service, launchd
               ## LaunchDaemon, …) — e.g. the ``repro-binary-cache`` role.
    ssUser     ## a per-user unit (systemd ``--user`` service, launchd
               ## LaunchAgent, …) — e.g. the ``repro daemon serve`` role.

  ServiceUnit* = object
    ## An OS-agnostic service description. The producers render this into
    ## the native unit + the native post-install enable hook.
    name*: string          ## unit base name, e.g. ``repro-binary-cache``
    description*: string
    execStart*: string     ## absolute (installed-prefix) command line
    scope*: ServiceScope
    wantedBy*: string      ## systemd target, default ``multi-user.target``

  RuntimeContract* = object
    ## The §5 contract, as data. The producers apply it uniformly.
    envDefaults*: seq[(string, string)]
      ## ``REPROBUILD_*`` / ``*_PREFIX`` / ``*_SRC`` (etc.) defaults the
      ## generated wrapper seeds with ``--set-default`` semantics (only
      ## set when the caller has not already exported the var), mirroring
      ## the flake's ``wrapProgram --set-default`` list (flake.nix
      ## §"wrapper"). Empty ⇒ no wrapper is generated and the component
      ## binary is installed directly at its ``installPrefix``.
    vendoredLibs*: seq[string]
      ## Absolute (or recipe-relative) paths of the runtime shared
      ## libraries to bundle into the package's private libdir
      ## (blake3/xxHash/sqlite/openssl/zstd/clingo for reprobuild
      ## itself). Empty ⇒ no private libdir and no RPATH patch — the M0
      ## two-binary sample's binaries need no vendored closure, so the
      ## RPATH half of the contract is a structural no-op there while the
      ## env-default wrapper half still applies.
    privateLibDirName*: string
      ## Sub-directory of ``usr/lib`` the vendored libs land in and the
      ## RPATH points at (default: the distribution name). Keeps one
      ## package's closure from colliding with another's on a shared
      ## prefix.

  PackageMetadata* = object
    ## Single source of truth for the human/registry metadata every format
    ## re-encodes into its own control/spec/manifest.
    maintainer*: string
    license*: string
    homepage*: string
    description*: string
    section*: string       ## deb ``Section`` / rpm ``Group`` (default ``utils``)
    priority*: string      ## deb ``Priority`` (default ``optional``)

  Distribution* = object
    ## The ONE definition. Producers translate it; they never re-derive
    ## components, wiring, or the runtime contract.
    name*: string
    version*: string
    arch*: string          ## canonical CPU token (``x86_64`` / ``aarch64``);
                           ## producers map it to per-format arch spellings.
    components*: seq[Executable]
    runtime*: RuntimeContract
    services*: seq[ServiceUnit]
    metadata*: PackageMetadata

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc hostArchToken*(): string =
  ## The canonical CPU token for the compiling host, used as the default
  ## ``Distribution.arch``. Matches the ``PlatformCpu`` spellings the
  ## catalog schema already uses (``packages_schema.nim``).
  case hostCPU
  of "amd64": "x86_64"
  of "arm64": "aarch64"
  else: hostCPU

proc runtimeContract*(envDefaults: openArray[(string, string)] = [];
                      vendoredLibs: openArray[string] = [];
                      privateLibDirName = ""): RuntimeContract =
  RuntimeContract(
    envDefaults: @envDefaults,
    vendoredLibs: @vendoredLibs,
    privateLibDirName: privateLibDirName)

proc service*(name, execStart: string; scope = ssSystem;
              description = ""; wantedBy = "multi-user.target"): ServiceUnit =
  ServiceUnit(name: name, execStart: execStart, scope: scope,
    description: (if description.len > 0: description else: name),
    wantedBy: wantedBy)

proc packageMetadata*(maintainer, description: string; license = "MIT";
                      homepage = ""; section = "utils";
                      priority = "optional"): PackageMetadata =
  PackageMetadata(maintainer: maintainer, description: description,
    license: license, homepage: homepage, section: section,
    priority: priority)

proc distribution*(name, version: string;
                   components: openArray[Executable];
                   metadata: PackageMetadata;
                   runtime = RuntimeContract();
                   services: openArray[ServiceUnit] = [];
                   arch = ""): Distribution =
  ## Assemble the typed install-tree definition. ``arch`` defaults to the
  ## compiling host's canonical token.
  var rt = runtime
  if rt.privateLibDirName.len == 0:
    rt.privateLibDirName = name
  Distribution(
    name: name, version: version,
    arch: (if arch.len > 0: arch else: hostArchToken()),
    components: @components,
    runtime: rt,
    services: @services,
    metadata: metadata)

# ---------------------------------------------------------------------------
# Component accessors — read the typed ``Executable`` install edge
# ---------------------------------------------------------------------------

proc componentName*(exe: Executable): string =
  ## The installed binary's base name. The Layer-1 constructors
  ## (``c_executable`` / ``nim_executable``) populate ``executableName``
  ## with the edge's ``into`` target, which is typically a path such as
  ## ``build/bin/greeter`` — so reduce it to a basename. Falls back to the
  ## producing edge's output basename for synthesised executables.
  if exe.cli.executableName.len > 0:
    exe.cli.executableName.extractFilename
  elif exe.install.outputs.len > 0:
    exe.install.outputs[0].extractFilename
  else:
    ""

proc componentSource*(exe: Executable): string =
  ## The recipe-relative path of the built binary (the output of the
  ## ``install`` build edge). This is the file the packaging step copies
  ## into the staged prefix.
  if exe.install.outputs.len == 0:
    raise newException(ValueError,
      "packaging: component '" & componentName(exe) &
      "' has no build output to package (its install edge declares no outputs)")
  exe.install.outputs[0]

proc componentInstallPrefix*(exe: Executable): string =
  ## The relative install dir within the package root (e.g. ``usr/bin``).
  if exe.installPrefix.len > 0: exe.installPrefix else: "usr/bin"

# ---------------------------------------------------------------------------
# Per-format arch spellings
# ---------------------------------------------------------------------------

proc debArch*(arch: string): string =
  ## Debian architecture token (``dpkg --print-architecture`` spellings).
  case arch
  of "x86_64": "amd64"
  of "aarch64": "arm64"
  else: arch

proc rpmArch*(arch: string): string =
  ## RPM ``BuildArch`` token (uname-style, matches ``x86_64`` already).
  arch

# ---------------------------------------------------------------------------
# Shell quoting
# ---------------------------------------------------------------------------

proc shq*(value: string): string =
  ## POSIX single-quote a literal for safe interpolation into the staging
  ## script. An embedded single quote is closed, escaped, and reopened.
  "'" & value.replace("'", "'\\''") & "'"

# ---------------------------------------------------------------------------
# §5 contract — the ONE payload-staging renderer
# ---------------------------------------------------------------------------

proc renderWrapperBody(d: Distribution; execRel: string): string =
  ## The generated env-seed wrapper (POSIX sh). Sets each
  ## ``RuntimeContract.envDefault`` with ``--set-default`` semantics
  ## (``: "${NAME:=value}"`` only assigns when unset, so an explicit
  ## dev/source override wins — exactly the flake's ``--set-default``
  ## behaviour) then execs the real binary resolved RELATIVE to the
  ## wrapper's own location, so the package is relocatable.
  var lines = @["#!/bin/sh",
    "# Generated by the reprobuild DSL packaging layer — §5 runtime",
    "# env-default contract. Do not edit; regenerate from the build graph."]
  for (name, value) in d.runtime.envDefaults:
    lines.add(": \"${" & name & ":=" & value & "}\"")
    lines.add("export " & name)
  lines.add("DIR=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)")
  lines.add("exec \"$DIR/" & execRel & "\" \"$@\"")
  lines.join("\n") & "\n"

proc renderPayloadStaging*(d: Distribution; rootExpr: string): string =
  ## Emit the shell fragment that stages the complete package *payload*
  ## into the directory named by ``rootExpr`` (a shell expression such as
  ## ``"$PAYLOAD"``). This is the SINGLE encoding of the §5 contract; the
  ## ``.deb`` / ``.rpm`` / ``.tar.gz`` producers all call it and differ
  ## only in the metadata they wrap around the result.
  ##
  ## Layout produced (relative to the package root):
  ##   * ``<installPrefix>/<name>``      — the env-seed wrapper (or the raw
  ##                                       binary when no env defaults)
  ##   * ``usr/libexec/<dist>/<name>``   — the real binary (when wrapped)
  ##   * ``usr/lib/<privateLibDir>/``    — vendored runtime libraries
  ##
  ## The RPATH of each wrapped binary is set to ``$ORIGIN/../lib/<dir>``
  ## (Linux) / ``@loader_path/../lib/<dir>`` (Darwin) so the vendored
  ## closure resolves without ``LD_LIBRARY_PATH`` — the loader-var
  ## injection the flake's compile-check forbids.
  let wrap = d.runtime.envDefaults.len > 0
  let libexecDir = "usr/libexec/" & d.name
  let libDir = "usr/lib/" & d.runtime.privateLibDirName
  var s: seq[string] = @[]
  s.add("set -eu")
  s.add("root=" & rootExpr)

  # Vendored runtime library closure (§5) — copied once, shared by every
  # wrapped component's RPATH.
  if d.runtime.vendoredLibs.len > 0:
    s.add("mkdir -p \"$root/" & libDir & "\"")
    for lib in d.runtime.vendoredLibs:
      s.add("cp " & shq(lib) & " \"$root/" & libDir & "/\"")

  for exe in d.components:
    let name = componentName(exe)
    if name.len == 0:
      raise newException(ValueError,
        "packaging: a component executable has no name and no output " &
        "basename to derive one from")
    let installPrefix = componentInstallPrefix(exe)
    let src = componentSource(exe)
    s.add("mkdir -p \"$root/" & installPrefix & "\"")
    if wrap:
      # Real binary under libexec; wrapper at the public install prefix.
      s.add("mkdir -p \"$root/" & libexecDir & "\"")
      s.add("cp " & shq(src) & " \"$root/" & libexecDir & "/" & name & "\"")
      s.add("chmod 0755 \"$root/" & libexecDir & "/" & name & "\"")
      if d.runtime.vendoredLibs.len > 0:
        # RPATH relative from usr/libexec/<dist> back down to usr/lib/<dir>.
        let rel = relativePath(libDir, libexecDir)
        when defined(macosx):
          s.add("install_name_tool -add_rpath " &
            shq("@loader_path/" & rel) &
            " \"$root/" & libexecDir & "/" & name & "\" || true")
        else:
          s.add("patchelf --force-rpath --set-rpath " &
            shq("$ORIGIN/" & rel) &
            " \"$root/" & libexecDir & "/" & name & "\"")
      # execRel: from <installPrefix> up to usr/libexec/<dist>/<name>.
      let execRel = relativePath(libexecDir & "/" & name, installPrefix)
      let wrapperBody = renderWrapperBody(d, execRel)
      s.add("cat > \"$root/" & installPrefix & "/" & name &
        "\" <<'REPRO_PKG_WRAP_EOF'")
      s.add(wrapperBody & "REPRO_PKG_WRAP_EOF")
      s.add("chmod 0755 \"$root/" & installPrefix & "/" & name & "\"")
    else:
      s.add("cp " & shq(src) & " \"$root/" & installPrefix & "/" & name & "\"")
      s.add("chmod 0755 \"$root/" & installPrefix & "/" & name & "\"")

  s.join("\n") & "\n"

proc payloadInputs*(d: Distribution): seq[string] =
  ## The set of files whose bytes the packaging edge depends on — every
  ## component binary plus every vendored library. Declared as build-edge
  ## ``inputs`` so a producer edge is content-addressed and rebuilds
  ## cache-hit-identically when nothing upstream changed.
  for exe in d.components:
    let src = componentSource(exe)
    if src notin result: result.add(src)
  for lib in d.runtime.vendoredLibs:
    if lib notin result: result.add(lib)

proc installedPaths*(d: Distribution): seq[string] =
  ## Every path the package installs, package-root-relative and
  ## leading-slash-absolute (``/usr/bin/foo``). Used to author the RPM
  ## ``%files`` manifest and the deb file list.
  let libexecDir = "/usr/libexec/" & d.name
  let libDir = "/usr/lib/" & d.runtime.privateLibDirName
  let wrap = d.runtime.envDefaults.len > 0
  for exe in d.components:
    let name = componentName(exe)
    result.add("/" & componentInstallPrefix(exe) & "/" & name)
    if wrap:
      result.add(libexecDir & "/" & name)
  for lib in d.runtime.vendoredLibs:
    result.add(libDir & "/" & lib.extractFilename)
