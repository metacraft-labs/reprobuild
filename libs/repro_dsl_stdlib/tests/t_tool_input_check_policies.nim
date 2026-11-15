## The input-check policy table the CLI reads and the tools' CLI specs say the
## same thing (Caching-Architecture.md, decision D2).
##
## Two halves have to agree, and they live in different libraries:
##
##   * the DECLARATION, `inputCheckPolicy hybrid` in a `package`'s `cli:`
##     block, compiled into the recipe provider, where a typed call of the
##     tool takes it as the default of its `actionCachePolicy`;
##   * the TABLE, `repro_core/tool_input_check_policies`, which lowering reads
##     for an edge that names the tool only in `toolIdentityRefs` (the C
##     convention's compile, archive and link edges), because no CLI spec is
##     visible there.
##
## Nothing in the compiler ties them together, so this file does: every table
## entry is checked against an edge the tool's own typed wrapper REGISTERS,
## not against the source text, so a declaration that stopped reaching the
## wrapper fails here the way it would fail a recipe.
##
## No mocks: the edges are the real stdlib wrappers', recorded in the real
## build-action registry.

import std/[options, os, unittest]

import repro_core/input_check_policy
import repro_core/tool_input_check_policies
import repro_project_dsl
# Aliased as `t_entropy_image_blessings.nim` explains: each `package` block
# emits a const named after the package.
import repro_dsl_stdlib/packages/gcc as gcc_module
import repro_dsl_stdlib/packages/clang as clang_module
import repro_dsl_stdlib/packages/binutils as binutils_module
import repro_dsl_stdlib/packages/sh as sh_module

{.experimental: "callOperator".}

const gccTool = gcc_module.gcc
const clangTool = clang_module.clang
const arTool = binutils_module.ar
const shTool = sh_module.sh

proc toEngine(policy: ActionCacheFingerprintPolicy): Option[FileFingerprintPolicy] =
  case policy
  of acfpUnstated: none(FileFingerprintPolicy)
  of acfpTimestamp: some(ffpTimestamp)
  of acfpChecksum: some(ffpChecksum)
  of acfpHybrid: some(ffpHybrid)

proc registeredPolicy(tool: string): ActionCacheFingerprintPolicy =
  ## The policy an edge the tool's typed wrapper records carries when the
  ## call site states none.
  resetBuildActionRegistry()
  case tool
  of "gcc":
    gccTool(compileOnly = true, output = "add.o", source = "add.c").
      actionCachePolicy
  of "clang":
    clangTool(compileOnly = true, output = "add.o",
      source = "add.c").actionCachePolicy
  of "ar":
    arTool(modifiers = "rcs", archive = "libm.a",
      objects = @["add.o"]).actionCachePolicy
  else:
    raise newException(ValueError, "no typed edge known for " & tool &
      "; add one here before adding the table entry")

suite "each tool the table names declares the policy itself":

  test "gcc, clang and ar declare hybrid on their typed edges":
    check registeredPolicy("gcc") == acfpHybrid
    check registeredPolicy("clang") == acfpHybrid
    check registeredPolicy("ar") == acfpHybrid

  test "a call site that states a policy keeps it":
    ## D2: "An edge that states a policy keeps it, timestamp included, so a
    ## project can still opt one edge out."
    resetBuildActionRegistry()
    let pinned = gccTool(compileOnly = true, output = "add.o",
      source = "add.c", actionCachePolicy = acfpTimestamp)
    check pinned.actionCachePolicy == acfpTimestamp

suite "the table and the CLI specs cannot drift apart":

  test "every table entry is backed by the same declaration on a real edge":
    check ToolInputCheckPolicies.len > 0
    for entry in ToolInputCheckPolicies:
      checkpoint("table entry: " & entry.tool)
      check registeredPolicy(entry.tool).toEngine() == some(entry.policy)

  test "the table names the file that carries each declaration":
    for entry in ToolInputCheckPolicies:
      checkpoint("table entry: " & entry.tool)
      check fileExists(currentSourcePath().parentDir().parentDir()
        .parentDir().parentDir() / entry.spec)

suite "the controls":

  test "a tool that declares nothing stays unstated and is not in the table":
    ## Without this, the checks above would pass against a wrapper generator
    ## that stamped hybrid on every tool.
    resetBuildActionRegistry()
    let direct = shTool(command = "echo hi", args = @[])
    check direct.actionCachePolicy == acfpUnstated
    check toolDeclaredInputCheckPolicy("sh").isNone
    check toolDeclaredInputCheckPolicy("").isNone

  test "the strongest declared policy wins":
    check strongestInputCheckPolicy(ffpTimestamp, ffpHybrid) == ffpHybrid
    check strongestInputCheckPolicy(ffpHybrid, ffpChecksum) == ffpChecksum
    check strongestInputCheckPolicy(ffpChecksum, ffpTimestamp) == ffpChecksum
    check strongestInputCheckPolicy(ffpHybrid, ffpHybrid) == ffpHybrid
