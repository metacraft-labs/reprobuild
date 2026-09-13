## Per-image entropy blessings: the engine's table and the tools' CLI specs
## say the same thing, and they say it about the right tools.
##
## # What this file is for
##
## `84b3a087` refused to entropy-bless the shell and wrote down why: a
## `bash <script>` action's `mrNonDeterministic` records are emitted by
## CHILDREN the script chose, never by the shell, so an ACTION-scoped waiver
## on `sh` would waive strangers. The mechanism that replaces it attributes
## each record to the image that emitted it and asks THAT tool's spec. Two
## halves have to agree for it to work, and they live in different libraries
## for a reason neither of them can fix:
##
##   * the DECLARATION is `nonDeterminism entropyBlessed, justification =
##     "..."` inside a `package`'s `cli:` block, compiled into the recipe
##     PROVIDER;
##   * the TABLE the engine reads is
##     `repro_core/entropy_blessings.EntropyBlessedTools`, because a capture
##     being graded has no access to any CLI spec and the record it is
##     grading belongs to a tool the action never invoked.
##
## Nothing in the compiler ties those together. Without this file the table
## could bless `curl` while no spec anywhere says anything about curl, and the
## only symptom would be cache entries published for actions nobody vouched
## for — the exact failure `84b3a087` refused, arrived at from the other side.
## So every entry in the table is checked here against a real, registered
## build edge, and the justification is compared for EQUALITY rather than for
## containment: a table entry that has drifted from its spec is a table entry
## whose stated reason is not the reason anybody wrote.
##
## # The controls, and why each is load-bearing
##
## `sh` must still come back UNBLESSED. Without that check every assertion
## here would pass against an implementation that blessed every tool, which
## is the shape of the waiver that was refused.
##
## `uuidgen` must come back with NO blessing. It is the one tool whose
## evidence is indistinguishable from `mktemp`'s — one `getrandom`, one
## process, one pid, no other field different — and whose printed bytes ARE
## its caller's product. If the lookup ever answered for it, the mechanism
## would have the same defect as the shell waiver.

import std/[options, os, strutils, unittest]

import repro_core
import repro_project_dsl
# Aliased for the reason `t_nim_entropy_blessing.nim` gives: each `package`
# block emits a const named after the package, and a plain `import` would
# shadow it with the module name.
import repro_dsl_stdlib/packages/mktemp as mktemp_module
import repro_dsl_stdlib/packages/git as git_module
import repro_dsl_stdlib/packages/sh as sh_module
import repro_dsl_stdlib/packages/nim as nim_module

{.experimental: "callOperator".}

const mktempTool = mktemp_module.mktemp
const gitTool = git_module.git
const shTool = sh_module.sh
const nimTool = nim_module.nim

proc mktempEdge(): BuildActionDef =
  resetBuildActionRegistry()
  mktempTool(args = @["-d"])

proc gitEdge(): BuildActionDef =
  resetBuildActionRegistry()
  gitTool(args = @["status", "--porcelain"])

proc specJustification(image: string): string =
  ## The justification a registered edge for `image` actually carries. This is
  ## read off a REGISTERED EDGE rather than off the source text, so it fails
  ## the same way a recipe would if the declaration ever stopped reaching the
  ## wrapper — which is how `dependencyPolicy` is lost for `nim.c` today.
  case image
  of "mktemp": mktempEdge().nonDeterminismJustification
  of "git": gitEdge().nonDeterminismJustification
  else: ""

suite "the tools the engine blesses per image bless themselves":

  test "mktemp's own CLI spec blesses entropy, with a reason":
    ## The tool that emits 23 of the 45 records CodeTracer's ten gates
    ## produce. Before this spec existed there was no `executable mktemp:`
    ## anywhere in the stdlib and therefore nowhere for the statement to live.
    let act = mktempEdge()
    check act.nonDeterminism == ndpEntropyBlessed
    check act.nonDeterminismJustification.len > 0

  test "git's own CLI spec blesses entropy, with a reason":
    ## `package git:` was provisioning-only until this change, exactly like
    ## `package bash:` still is — so this assertion also pins that git GREW a
    ## CLI surface, which is what makes the declaration reachable at all.
    let act = gitEdge()
    check act.nonDeterminism == ndpEntropyBlessed
    check act.nonDeterminismJustification.len > 0

  test "each blessing names what the tool draws randomness FOR":
    ## A justification is required by the DSL, so "it is non-empty" is checked
    ## by the compiler and proves nothing here. What has to be true is that
    ## the reason is about THAT TOOL's use of randomness — the standard
    ## `packages/nim.nim` set — rather than about the inconvenience of the
    ## signal.
    check "temporary name" in mktempEdge().nonDeterminismJustification
    check "rename away" in gitEdge().nonDeterminismJustification

  test "each blessing keeps its hands off the clock":
    ## Both tools' outputs can depend on a clock — `git commit`'s object hash
    ## depends on its committer timestamp — and `mrTimeRead` is a separate
    ## signal this engine does not grade. A blessing that quietly read as
    ## "this tool is deterministic" would be claiming something neither spec
    ## is entitled to claim, so each says so in as many words.
    check "ENTROPY only" in mktempEdge().nonDeterminismJustification
    check "ENTROPY only" in gitEdge().nonDeterminismJustification
    check "mrTimeRead" in gitEdge().nonDeterminismJustification

suite "the engine's per-image table and the CLI specs cannot drift apart":

  test "every entry in the table is backed by a real blessed edge":
    ## THE CORRESPONDENCE THIS FILE EXISTS FOR. The engine reads the table;
    ## a reviewer reads the spec. An entry with no spec behind it would be a
    ## waiver nobody wrote, and it would look exactly like one that was.
    check EntropyBlessedTools.len > 0
    for tool in EntropyBlessedTools:
      let justification = specJustification(tool.image)
      checkpoint("table entry: " & tool.image)
      # An image this file does not know how to build an edge for fails here
      # rather than being skipped — adding a blessing without adding its
      # check is the thing that must not be possible.
      check justification.len > 0
      check justification == tool.justification

  test "the table names the file that carries each declaration":
    ## The `spec` field is what a diagnostic sends an operator to. A stale
    ## path there sends them to a file that does not say what they were told
    ## it says.
    for tool in EntropyBlessedTools:
      checkpoint("table entry: " & tool.image)
      check tool.spec.len > 0
      check fileExists(currentSourcePath().parentDir().parentDir()
        .parentDir().parentDir() / tool.spec)

  test "a resolved image path finds its blessing however it is spelled":
    ## The lookup is given whatever an `mrProcessExec` record carried, which
    ## is an absolute path into a store, a profile, or a PortableGit tree.
    check entropyBlessedTool("/usr/bin/mktemp").isSome
    check entropyBlessedTool(
      "/home/u/.nix-profile/bin/mktemp").get.image == "mktemp"
    check entropyBlessedTool(
      "/nix/store/abc123-git-2.51.0/bin/git").get.image == "git"
    check entropyBlessedTool(
      "C:\\Users\\u\\scoop\\apps\\git\\current\\bin\\git.exe").get.image ==
      "git"
    check entropyBlessedTool("C:\\PortableGit\\bin\\GIT.EXE").get.image ==
      "git"

suite "the controls that make the checks above mean something":

  test "sh is still NOT blessed":
    ## The distinguishing control, and the one the whole design rests on. This
    ## file is about widening the set of blessed tools; if the widening had
    ## reached `sh`, every measurement in `packages/sh.nim` would have been
    ## overturned silently and `t_shell_entropy_is_not_blessed.nim` would be
    ## the only thing left saying otherwise.
    resetBuildActionRegistry()
    let direct = shTool(command = "echo hi", args = @[])
    check direct.nonDeterminism == ndpUnblessed
    resetBuildActionRegistry()
    let gate = sh_module.shell(command = "bash ci/test/gate.sh")
    check gate.nonDeterminism == ndpUnblessed
    check entropyBlessedTool("/bin/sh").isNone
    check entropyBlessedTool("/usr/bin/bash").isNone

  test "uuidgen has no blessing, in the table or anywhere else":
    ## The pair that makes per-image attribution more than bookkeeping. In the
    ## capture, `uuidgen` and `mktemp` produce records that differ in NO FIELD
    ## but the emitting pid: one `getrandom`, one process, no caller token on
    ## Linux. What separates them is the claim each tool's author can make —
    ## mktemp's bytes name scratch space, uuidgen's bytes ARE the value its
    ## caller keeps — and a table that answered for both would be the shell
    ## waiver with extra steps.
    check entropyBlessedTool("/usr/bin/uuidgen").isNone
    check entropyBlessedTool("/usr/bin/openssl").isNone
    check entropyBlessedTool("/usr/bin/date").isNone
    # `python3` for the same reason and a sharper one: measured, its single
    # startup `getrandom` IS the `PYTHONHASHSEED` draw (`PYTHONHASHSEED=0
    # python3 -c 'print(1)'` emits no record at all), and those bytes decide
    # set and dict iteration order -- entropy that reaches a product.
    check entropyBlessedTool(
      "/nix/store/abc-python3-3.12.12/bin/python3").isNone

  test "an unresolvable emitter gets no blessing":
    ## What the engine passes when no `mrProcessExec` record in the capture
    ## names the entropy record's pid. Failing closed here is what keeps an
    ## unattributable read consequential.
    check entropyBlessedTool("").isNone
    check entropyBlessedTool("/").isNone

  test "nim IS blessed, at the ACTION level, and is not in the table":
    ## The two scopes are different mechanisms and must not be confused. nim's
    ## blessing covers its whole process tree — gcc and ld included — because
    ## that tree is "what nim does"; it is stamped onto the action and needs
    ## no per-image entry. Putting nim in the table as well would say
    ## something narrower and untrue: that a `nim` PROCESS under somebody
    ## else's action is vouched for.
    resetBuildActionRegistry()
    let compile = nimTool.c(
      source = "src" / "hello.nim",
      binary = "build" / "bin" / "hello")
    check compile.nonDeterminism == ndpEntropyBlessed
    check entropyBlessedTool("/usr/bin/nim").isNone
