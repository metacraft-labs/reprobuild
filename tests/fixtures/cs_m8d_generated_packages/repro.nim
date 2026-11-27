## The fixture package of
## `tests/integration/test_cs_m8d_generated_packages_add_completion.nim`.
##
## One executable with a `cli:` section, `csm8d-tool`, compiled with `nim.c`
## from `src/csm8d_tool.nim` (which imports this file, so it compiles in the
## DSL's thin mode, and prints its own completion script for
## `--printCompletion=<shell>`), and the package outputs reprobuild generates:
## for a Linux target a .deb, an .rpm, an Arch package, a tarball, an
## AppImage and an installed prefix; for a Windows target an MSI, a tarball
## and a Scoop manifest over it. Nothing here mentions shell completion: the
## producers add it on their own.
##
## The test copies this package to a scratch directory and fills in:
##
## * `__CLISPEC_SRC__`: nim-cli-spec's `src/` directory;
## * `__REPRO_DSL_SRC__`: this repository's `libs/repro_project_dsl/src`,
##   which the program's thin import of this file needs;
## * `__FORMATS__`: the formats to build, as Nim string literals
##   (`"deb", "rpm", "arch", "tarball", "appimage", "prefix"` for Linux;
##   `"msi-authoring", "msi", "tarball", "scoop"` for Windows, where
##   `msi-authoring` is the MSI's payload and `.wxs` without the WiX tools,
##   which run on Windows only);
## * `__OMIT_COMPLETION__`: `true` for the opt-out, `false` otherwise;
## * `__TARGET_OS__`: `linux` or `windows`, the system the program and its
##   packages are for;
## * `__WINDOWS_CC__`: for a Windows program built on another system, a C
##   compiler driver that targets Windows (a `zig cc -target
##   x86_64-windows-gnu` wrapper), which the Nim compile is given with
##   `--os:windows --cpu:amd64 --cc:clang`; "" for a native build.

import repro_project_dsl

when reproDslMode != rdmThin:
  # Imported under another name, so `nim` below is the tool, not the module.
  import reprobuild/dsl/packages/nim as nimTool
  import repro_dsl_stdlib/packaging
  import repro_dsl_stdlib/packaging/producers/installed_prefix

const
  ClispecSrc = "__CLISPEC_SRC__"
  ReproDslSrc = "__REPRO_DSL_SRC__"
  Formats = [__FORMATS__]
  OmitCompletion = __OMIT_COMPLETION__
  TargetOs = "__TARGET_OS__"
  WindowsCc = "__WINDOWS_CC__"

package cs_m8d_generated_packages:
  defaultToolProvisioning "path"

  # Build-host tools, so a `--target` build resolves them for the build
  # host too. The packaging tools are the producers' selectors
  # (`DpkgDebSelector`, `RpmbuildSelector`, ...); a recipe lists them
  # because a producer runs inside `build:`, after the tool set is read.
  nativeBuildDeps:
    # The tools of a Linux build host. On a Windows host the test replaces
    # the lines between these markers with that host's (the WiX tools
    # instead of the Linux packagers).
    # >>> host tools
    "nim"
    "gcc"
    "zig >=0.14 <0.15"
    "sh"
    "install-file"
    "patchelf"
    "readelf"
    "tar"
    "gzip"
    "dpkg-deb"
    "rpmbuild"
    "find"
    "diff"
    "sed"
    "grep"
    "bsdtar"
    "appimagetool"
    "appimage-runtime"
    "file"
    # The installed prefix's edges name these by name and, unlike the
    # producers, do not declare them on the package (a recipe using
    # `installedPrefix` lists them, as reprobuild's own does).
    "cp"
    "ln"
    "mkdir"
    "rm"
    "chmod"
    "head"
    "printf"
    "awk"
    "sort"
    "ls"
    "mktemp"
    "basename"
    "mv"
    "touch"
    # The assembly strips every image's debug info with it.
    "llvm-objcopy"
    # <<< host tools

  executable csm8dTool:
    name: "csm8d-tool"
    cli:
      help "The fixture's program with a command-line description"
      flag printCompletion is string, default = "",
        help = "Print this shell's completion script"

  build:
    let site = packagingSite("cs_m8d_generated_packages")
    let metadata = DistMetadata(
      summary: "Clispec completion packaging fixture",
      description: "A one-binary distribution with a cli: description.",
      maintainer: "Reprobuild Developers <dev@reprobuild.invalid>",
      vendor: "Reprobuild",
      license: "MIT",
      homepage: "https://github.com/metacraft-labs/reprobuild",
      section: "devel",
      priority: "optional",
      # The MSI's: constant across this product's versions.
      upgradeCode: "{6B0E3F52-1C7A-4D89-9E25-3A4F8C1D7B60}")
    var artifacts: seq[BuildActionDef]
    if TargetOs == "windows":
      # A Windows program. Built here with the Nim compile's own cross
      # flags when `WindowsCc` names a Windows-targeting C driver (there is
      # no Windows `--target`), natively otherwise.
      let exe =
        if WindowsCc.len > 0:
          nim.c(
            source = "src/csm8d_tool.nim",
            output = "build/bin/csm8d-tool.exe",
            paths = @[ClispecSrc, ReproDslSrc],
            nimcache = "build/nimcache/csm8d-tool-windows",
            skipUserCfg = true,
            defines = @["release"],
            os = "windows",
            cpu = "amd64",
            cc = "clang",
            clangExe = WindowsCc,
            clangLinkerExe = WindowsCc,
            actionId = "csm8d.compile")
        else:
          nim.c(
            source = "src/csm8d_tool.nim",
            binary = "build/bin/csm8d-tool.exe",
            paths = @[ClispecSrc, ReproDslSrc],
            nimcache = "build/nimcache/csm8d-tool",
            skipUserCfg = true,
            defines = @["release"],
            actionId = "csm8d.compile")
      var dist = newDistribution("csm8d-tool", "0.1.0", toWindows,
        prefix = "", architecture = "x86_64", layout = plWindowsTree,
        stagingRoot = "build/dist/stage", outputDir = "build/dist")
      dist.components = @[executableComponent(exe.outputs[0], @[exe])]
      dist.omitShellCompletion = OmitCompletion
      dist.metadata = metadata
      # One tarball, which the Scoop manifest describes.
      var tarball: PackagedArtifact
      var tarballBuilt = false
      for format in Formats:
        if format in ["tarball", "scoop"] and not tarballBuilt:
          tarball = tarballPackage(dist, site)
          tarballBuilt = true
          artifacts.add(tarball.edge)
      for format in Formats:
        case format
        of "msi-authoring":
          let authoring = msiAuthoring(dist, site)
          artifacts.add(authoring.wxsEdge)
          for edge in authoring.tree.terminal:
            artifacts.add(edge)
        of "msi": artifacts.add(msiPackage(dist, site).edge)
        of "tarball": discard
        of "scoop": artifacts.add(scoopPackage(dist, tarball, site).edge)
        else:
          raise newException(ValueError, "unknown format " & format)
      discard collect("packages", artifacts)
    else:
      let target = activeTargetTripleTag()
      let exe = nim.c(
        source = "src/csm8d_tool.nim",
        binary = "build/bin/csm8d-tool",
        paths = @[ClispecSrc, ReproDslSrc],
        nimcache = "build/nimcache/csm8d-tool",
        skipUserCfg = true,
        defines = @["release"],
        actionId = "csm8d.compile")
      # Where the compile wrote the binary: `build@<triple>/bin/...` for a
      # target build.
      let binary = exe.outputs[0]
      let architecture = if target.len == 0: "x86_64" else: "armhf"

      var dist = newDistribution("csm8d-tool", "0.1.0", toLinux,
        prefix = "/usr", architecture = architecture,
        stagingRoot = "build/dist/stage", outputDir = "build/dist")
      dist.components = @[executableComponent(binary, @[exe])]
      dist.omitShellCompletion = OmitCompletion
      dist.metadata = metadata
      # `.#packages`: every artifact, and the installed prefix's assembly
      # and its builder-path gate.
      for format in Formats:
        case format
        of "deb": artifacts.add(debPackage(dist, site).edge)
        of "rpm": artifacts.add(rpmPackage(dist, site).edge)
        of "arch": artifacts.add(archPackage(dist, site).edge)
        of "tarball": artifacts.add(tarballPackage(dist, site).edge)
        of "appimage": artifacts.add(appImagePackage(dist, site).edge)
        of "prefix":
          let spec = InstalledPrefixSpec(
            name: "csm8d",
            triple: (if target.len == 0: "x86_64-unknown-linux-gnu"
                     else: target),
            output: targetKeyedOutputName("build") & "/prefix",
            entries: @[PrefixEntry(source: binary, dest: "bin/csm8d-tool",
              producer: exe.id)],
            systemSonames: @GlibcSonames,
            omitShellCompletion: OmitCompletion)
          let prefix = installedPrefix(spec, activeProviderProjectRoot())
          artifacts.add(prefix.assemble)
          artifacts.add(prefix.gate)
        else:
          raise newException(ValueError, "unknown format " & format)
      discard collect("packages", artifacts)
