## Windows-Build-Correctness M6 — the entropy blessing is a property of the
## TOOL, and an ordinary `nim.c(...)` edge inherits it with nothing on the
## edge.
##
## The design the user asked for, verbatim: "I would use `nim.c` normally and
## it will just do the right thing because `nim.nim` in reprobuild has
## indicated that randomness is not a problem for nim." So the assertion that
## matters is not that a blessing can be expressed — it is that a recipe which
## has never heard of entropy gets one anyway.
##
## Why this needs its own test rather than trusting the plumbing. The blessing
## rides the same route `dependencyPolicy` does, from the `cli:` block to the
## registered `BuildActionDef`, and `dependencyPolicy` DOES NOT SURVIVE THAT
## ROUTE for `nim.c`: the hand-written alias in `packages/nim.nim` takes a
## `dependencyPolicy` parameter defaulting to `defaultDependencyPolicy()` and
## hands it to `compileDependencyPolicy`, which builds a fresh value — so the
## `dependencyPolicy automaticMonitor` written under `cli:` reaches every
## `nim.js` edge and no `nim.c` edge at all. A blessing that travelled as a
## formal parameter would be lost the same way, silently, on the one tool this
## milestone blesses. It is therefore spliced into the generated wrapper's
## `recordToolInvocation` call as a literal, which no alias can drop and no
## call site can override. The last test in this file is the guard on that,
## and it is the reason the file exists.

import std/[os, osproc, strutils, unittest]

import repro_project_dsl
# Imported under an alias on purpose: the `package nim:` block inside that
# module emits a const named `nim`, and a plain `import` would shadow it with
# the module name and break `nim.c(...)` resolution -- the same reason
# reprobuild's own `repro.nim` reaches the const through the `uses:` pass.
import repro_dsl_stdlib/packages/nim as nim_module
import repro_dsl_stdlib/packages/gcc as gcc_module

const nimTool = nim_module.nim
const gccTool = gcc_module.gcc

# Two `defineCliInterface` tools declared for the second-front-end cases
# below. They are real top-level declarations, so the assertions read the
# blessing off a registered edge rather than off the parser.
defineCliInterface justifiedTool, "m6-justified":
  nonDeterminism entropyBlessed,
    justification = "randomness is used only for scratch file names"
  subcmd "run":
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    outputs output

defineCliInterface plainTool, "m6-plain":
  subcmd "run":
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    outputs output

suite "M6 nim is blessed, once, in its own CLI spec":

  test "an ordinary nim.c edge is blessed with nothing on the edge":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "hello.nim",
      binary = "build" / "bin" / "hello")
    check act.nonDeterminism == ndpEntropyBlessed

  test "the blessing carries the reason the spec had to give for it":
    ## The DSL refuses `nonDeterminism entropyBlessed` without a
    ## justification, and the justification is what the engine quotes when it
    ## decides to keep caching. An empty one here would mean the blessing
    ## takes effect while the reason for it never reaches a reader.
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "hello.nim",
      binary = "build" / "bin" / "hello")
    check act.nonDeterminismJustification.len > 0
    check "nimcache" in act.nonDeterminismJustification

  test "it is declared on the TOOL, so nim.js inherits it too":
    ## The statement sits under `cli:`, above the subcommands, exactly where
    ## `dependencyPolicy automaticMonitor` sits. A subcommand-scoped
    ## declaration would pass the `nim.c` test above and silently leave every
    ## other nim subcommand unblessed.
    resetBuildActionRegistry()
    let act = nimTool.js(
      source = "src" / "web.nim",
      output = "build" / "web.js")
    check act.nonDeterminism == ndpEntropyBlessed

  test "every shape of nim.c edge carries it, not just the simple one":
    ## `nim.c` has a large parameter surface and several post-registration
    ## mutation steps (`appendRegisteredActionToolIdentityRefs`,
    ## `maybeTagPublicInterface`, the nimcache-derived dependency policy).
    ## The blessing must survive all of them.
    resetBuildActionRegistry()
    let lib = nimTool.c(
      source = "src" / "shim.nim",
      binary = "build" / "lib" / "shim32.dll",
      appLib = true,
      cpu = "i386",
      threadsOn = true,
      passL = @["-static-libgcc", "-Wl,--kill-at"],
      nimcache = "build" / "nimcache" / "shim32",
      cacheable = true)
    check lib.nonDeterminism == ndpEntropyBlessed
    let uncached = nimTool.c(
      source = "src" / "tool.nim",
      binary = "build" / "bin" / "tool",
      cacheable = false)
    check uncached.nonDeterminism == ndpEntropyBlessed

suite "M6 the blessing does not leak to tools that were not given one":

  test "gcc is UNBLESSED, because nobody has justified blessing it":
    ## The distinguishing case. Without it every assertion above would pass
    ## against an implementation that blessed everything -- which is the same
    ## as having no policy, and is how a safety rule becomes decoration.
    ##
    ## gcc is deliberately not blessed here rather than incidentally: a C
    ## compiler's randomness has not been characterised in this milestone,
    ## and "do not bless anything you cannot justify" applies to the tools
    ## left alone as much as to the one blessed.
    resetBuildActionRegistry()
    # gcc's CLI spec declares an anonymous ``call:``, whose generated
    # wrapper is the call operator on the package const.
    let act = gccTool(
      source = "src" / "main.c",
      output = "build" / "main.o",
      compileOnly = true)
    check act.nonDeterminism == ndpUnblessed
    check act.nonDeterminismJustification.len == 0

  test "an edge cannot bless the tool it happens to call":
    ## The user's rule: "This blessing will be done in the CLI spec of the
    ## program, not on the edge definition." A recipe author must not be able
    ## to vouch for someone else's compiler, so the generated wrapper does
    ## not expose the blessing as a parameter at all -- there is no
    ## `nonDeterminism = ...` argument to pass.
    ##
    ## Asserted at COMPILE TIME, because that is where the guarantee lives:
    ## if the wrapper ever grew the formal, this would start compiling and
    ## the blessing would have quietly become an edge property.
    check not compiles(gccTool(
      source = "src" / "main.c",
      output = "build" / "main.o",
      nonDeterminism = ndpEntropyBlessed))
    check not compiles(nimTool.c(
      source = "src" / "hello.nim",
      binary = "build" / "bin" / "hello",
      nonDeterminism = ndpUnblessed))

suite "M6 the second CLI front end carries it too":

  test "a defineCliInterface tool's blessing reaches its edges":
    ## `defineCliInterface` and `package` are PARALLEL parsers of the same
    ## surface (`parseInterfaceDependencyPolicy` vs
    ## `parseCommandDependencyPolicy`, and now two copies of the blessing
    ## arm). A declaration wired into only one of them is ignored in the
    ## other with no diagnostic at all, and for a blessing "ignored" means
    ## the tool stays uncacheable while its spec says otherwise.
    ##
    ## `justifiedTool` is declared at the top of this module, so this asserts
    ## the value travelling all the way to a registered edge rather than
    ## merely parsing.
    resetBuildActionRegistry()
    let act = justifiedTool.run(output = "build" / "out.bin")
    check act.nonDeterminism == ndpEntropyBlessed
    check "scratch file names" in act.nonDeterminismJustification

  test "an unblessed defineCliInterface tool stays unblessed":
    resetBuildActionRegistry()
    let act = plainTool.run(output = "build" / "plain.bin")
    check act.nonDeterminism == ndpUnblessed

suite "M6 the DSL refuses a blessing it cannot quote":
  ## These three cases drive a REAL `nim check` over generated modules rather
  ## than `compiles()`.
  ##
  ## `compiles()` was tried first and is unusable here: `defineCliInterface`
  ## emits top-level declarations, so its expansion fails inside the template
  ## `compiles` needs — for EVERY input, well-formed or not. The refusal cases
  ## therefore passed vacuously, and mutation-testing caught it: deleting the
  ## justification requirement outright left them green. The positive control
  ## below is what turns that failure mode into a test failure, and it is the
  ## reason this suite costs a subprocess.

  proc checkModule(name, body: string): tuple[ok: bool; output: string] =
    ## Write a module into the repo tree (so the root `config.nims` supplies
    ## the search paths) and run `nim check` on it.
    let root = currentSourcePath().parentDir.parentDir.parentDir.parentDir
    let dir = root / "build" / "test-tmp" / "m6-blessing-refusal"
    createDir(dir)
    let path = dir / (name & ".nim")
    writeFile(path, body)
    let (output, code) = execCmdEx(
      "nim check --hints:off --warnings:off " & quoteShell(path),
      workingDir = root)
    (code == 0, output)

  proc interfaceModule(decl: string): string =
    @["import repro_project_dsl",
      "defineCliInterface refusalTool, \"m6-refusal\":",
      decl,
      "  subcmd \"run\":",
      "    flag output is string, alias = \"-o\", role = output, " &
        "required = true"].join("\n") & "\n"

  test "a justified blessing compiles (the positive control)":
    ## Without this, the two refusals below prove nothing: `nim check` failing
    ## is only evidence about the blessing if the well-formed twin passes.
    let outcome = checkModule("ok", interfaceModule(
      "  nonDeterminism entropyBlessed," & "\n" &
      "    justification = \"randomness names scratch files only\""))
    check outcome.ok

  test "entropyBlessed without a justification is refused":
    ## "Do not bless anything you cannot justify" is only a rule if the
    ## compiler asks for the reason. The message is asserted too, because a
    ## refusal for some unrelated reason would satisfy the exit code.
    let outcome = checkModule("unjustified", interfaceModule(
      "  nonDeterminism entropyBlessed"))
    check not outcome.ok
    check "requires justification" in outcome.output

  test "a misspelt policy word is refused, not silently inherited":
    ## `dependencyPolicy` falls back to the inherited value on an unknown
    ## word. A blessing must not: a misspelling that silently inherited a
    ## blessing from an enclosing scope would fail OPEN, and one that
    ## silently inherited `ndpUnblessed` would look like a blessing that "did
    ## not take", with nothing anywhere to say so.
    let outcome = checkModule("misspelt", interfaceModule(
      "  nonDeterminism entropyBlest," & "\n" &
      "    justification = \"typo in the policy word\""))
    check not outcome.ok
    check "expects entropyBlessed or unblessed" in outcome.output
