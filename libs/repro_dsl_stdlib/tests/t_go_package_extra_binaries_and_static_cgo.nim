## `go_package`: several commands from one module, and static cgo.
##
## THE NEED. A Go module that ships several commands from one `go.sum` (a
## consensus client: beacon node, validator, a control tool, a keystore
## tool) and binds C libraries through cgo (BLS signatures, KZG
## commitments) has to run on distributions whose libc the build host does
## not have. `extraBinaries` builds the further commands in the same edge;
## `staticCgo` makes zig, through `adapters/cross_zig`'s wrappers, the C
## compiler and external linker for the host CPU's musl, and asks Go for a
## static executable.
##
## THE CONSTRAINT. Both options default to off, and with both off the
## emitted build edge is exactly the literal pinned in the first suite: its
## script is part of the action fingerprint, so any drift rebuilds every Go
## recipe in the catalog. The options did not change it; the assembler
## path rewrite (last suite) did, deliberately, because without it the
## binary's bytes depended on the checkout's path.
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED. Nothing is mocked. The
## constructor is called as a recipe calls it, with no provider project
## root (so no fetch edge and no wrapper edge: the constructor takes its
## relative-path branches, which is also what interface extraction sees),
## and the assertions read the script and the declared outputs, inputs and
## tool references of the actions the registry holds. That the static
## build links and runs is shown end to end by the from-source recipes
## that use it, not here.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/adapters/cross_zig
import repro_dsl_stdlib/constructors/go_package
import repro_dsl_stdlib/types/package_result

const Pkg = "goProbeSource"

proc scriptOf(act: BuildActionDef): string =
  ## The `sh -c` script of an inline exec action: its last argv element.
  var argv: seq[string] = @[]
  for arg in act.call.arguments:
    if arg.nimType == "seq[string]":
      for v in arg.encodedValue.split('\x1f'):
        argv.add(v)
    else:
      argv.add(arg.encodedValue)
  check argv.len >= 3
  argv[^1]

proc buildOf(r: GoPackageResult): BuildActionDef =
  ## The registered build edge (the result carries the definition too, but
  ## the registry is what the engine emits from).
  for act in registeredBuildActions():
    if act.id == r.compileEdge.id:
      return act
  r.compileEdge

template withPackage(body: untyped) =
  resetBuildActionRegistry()
  setCurrentOwningPackageOverride(Pkg)
  try:
    body
  finally:
    clearCurrentOwningPackageOverride()

suite "go_package: defaults are unchanged":

  test "the build script is the pinned literal":
    withPackage:
      let r = go_package("hello", mainPackage = "./cmd/hello",
        ldflags = "-X main.version=v1", tags = @["a"])
      let act = buildOf(r)
      check act.id == "go-build-" & Pkg
      check scriptOf(act) ==
        "set -e; mkdir -p \".repro/build/go/out/usr/bin\"; cd \"src\"; " &
        "mkdir -p \".repro/build/go/toolexec\"; " &
        "printf '%s' '" & goAsmTrimpathWrapper() & "' > " &
        "\".repro/build/go/toolexec/asm-trimpath\"; " &
        "chmod 755 \".repro/build/go/toolexec/asm-trimpath\"; " &
        "GOMODCACHE=\".repro/build/go/modcache\" " &
        "GOCACHE=\".repro/build/go/cache\" " &
        "REPRO_GO_ASM_TRIMPATH=\".repro/build/go/modcache\" GOPROXY=off " &
        "GOFLAGS=-mod=mod CGO_ENABLED=0 go build -trimpath " &
        "-toolexec \".repro/build/go/toolexec/asm-trimpath\" -tags \"a\" " &
        "-ldflags \"-X main.version=v1\" " &
        "-o \".repro/build/go/out/usr/bin/hello\" \"./cmd/hello\""
      check act.outputs == @[".repro/build/go/out/usr/bin/hello"]
      check act.deps == @["go-mod-download-" & Pkg]
      check act.inputs == @[".repro/build/go/mod-download.stamp"]
      check act.toolIdentityRefs == @["sh", "mkdir", "printf", "chmod", "go"]

  test "cgo = true alone still uses the host toolchain, as before":
    withPackage:
      let s = scriptOf(buildOf(go_package("hello", cgo = true)))
      check "CGO_ENABLED=1 go build" in s
      check "CC=" notin s
      check "netgo" notin s
      check "-linkmode" notin s

suite "go_package: extraBinaries":

  test "each extra command is built by the same edge into the same bin":
    withPackage:
      let r = go_package("beacon-chain", mainPackage = "./cmd/beacon-chain",
        extraBinaries = @[("validator", "./cmd/validator"),
                          ("prysm-keystores", "./tools/keystores")])
      let act = buildOf(r)
      check act.outputs == @[
        ".repro/build/go/out/usr/bin/beacon-chain",
        ".repro/build/go/out/usr/bin/validator",
        ".repro/build/go/out/usr/bin/prysm-keystores"]
      let s = scriptOf(act)
      check s.count("go build ") == 3
      check "-o \".repro/build/go/out/usr/bin/validator\" \"./cmd/validator\"" in s
      check ("-o \".repro/build/go/out/usr/bin/prysm-keystores\" " &
        "\"./tools/keystores\"") in s
      # `set -e` stops at the first failing command, so a later binary is
      # never built against a half-failed edge.
      check s.startsWith("set -e; ")
      # One edge: no second build action appeared.
      var builds = 0
      for a in registeredBuildActions():
        if a.id.startsWith("go-build-"): inc builds
      check builds == 1

  test "a name that collides or is a path is refused":
    withPackage:
      expect ValueError:
        discard go_package("a", extraBinaries = @[("a", "./cmd/a")])
      expect ValueError:
        discard go_package("a", extraBinaries = @[("b", "./x"), ("b", "./y")])
      expect ValueError:
        discard go_package("a", extraBinaries = @[("bin/b", "./cmd/b")])
      expect ValueError:
        discard go_package("a", extraBinaries = @[("", "./cmd/b")])

suite "go_package: staticCgo":

  test "the musl triple follows the CPU, and an unlisted CPU is refused":
    check goStaticCgoTriple("amd64") == "x86_64-unknown-linux-musl"
    check goStaticCgoTriple("arm64") == "aarch64-unknown-linux-musl"
    expect ValueError:
      discard goStaticCgoTriple("riscv64")

  test "zig's wrappers are CC and CXX, with caches in scratch":
    withPackage:
      let act = buildOf(go_package("validator",
        mainPackage = "./cmd/validator", staticCgo = true))
      let s = scriptOf(act)
      let wrappers = zigCrossWrapperDir(".", goStaticCgoTriple())
      check "CGO_ENABLED=1 " in s
      check ("CC=\"" & wrappers & "/cc\"") in s
      check ("CXX=\"" & wrappers & "/c++\"") in s
      check "ZIG_GLOBAL_CACHE_DIR=\".repro/build/go/zig-cache/global\"" in s
      check "ZIG_LOCAL_CACHE_DIR=\".repro/build/go/zig-cache/local\"" in s
      check "-tags \"netgo,osusergo\"" in s
      check "-ldflags \"-linkmode external -extldflags -static\"" in s
      check "zig" in act.toolIdentityRefs

  test "the recipe's tags and ldflags are kept, the static ones appended":
    withPackage:
      let s = scriptOf(buildOf(go_package("validator",
        ldflags = "-X main.v=1", tags = @["blst_enabled", "netgo"],
        staticCgo = true,
        extraBinaries = @[("prysmctl", "./cmd/prysmctl")])))
      # `netgo` is not repeated; the recipe's order is kept.
      check s.count("-tags \"blst_enabled,netgo,osusergo\"") == 2
      check s.count(
        "-ldflags \"-X main.v=1 -linkmode external -extldflags -static\"") == 2
      check s.count("CC=\"") == 2

  test "the merge helpers are identities when static cgo is off":
    check goMergedTags(@["x"], false) == @["x"]
    check goMergedLdflags("-s", false) == "-s"
    check goMergedLdflags("", true) == GoStaticCgoLdflags

suite "go_package: assembly paths are rewritten for every file":

  test "every go build runs under the wrapper, written once per edge":
    # An assembly file #included from another directory keeps its absolute
    # path under -trimpath alone (gnark-crypto's `field/asm/*.s` put the
    # module cache's absolute path into geth and prysm).
    withPackage:
      let s = scriptOf(buildOf(go_package("a",
        extraBinaries = @[("b", "./cmd/b")])))
      check s.count("printf '%s'") == 1
      check s.count("-toolexec \".repro/build/go/toolexec/asm-trimpath\"") == 2
      check s.count("REPRO_GO_ASM_TRIMPATH=\".repro/build/go/modcache\"") == 2
      # Not -asmflags: go build records it in the binary.
      check "-asmflags" notin s
      check s.find("chmod 755") < s.find("go build")

  test "the wrapper only touches the assembler's -trimpath":
    let w = goAsmTrimpathWrapper()
    check '\'' notin w
    check w.startsWith("#!/bin/sh\n")
    check "asm|asm.exe) ;;" in w
    check "*) exec \"$tool\" \"$@\" ;;" in w
    check "a=\"$a;$REPRO_GO_ASM_TRIMPATH\"" in w
    check "[ \"$a\" = -trimpath ]" in w
