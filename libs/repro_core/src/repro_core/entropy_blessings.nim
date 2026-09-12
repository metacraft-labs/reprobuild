## Windows-Build-Correctness M6, continued — WHICH TOOL'S randomness a given
## entropy observation is about.
##
## THE GAP THIS CLOSES. `NonDeterminismPolicy` (dependency_gathering.nim) is
## ACTION-scoped: it is stamped onto an action from the CLI spec of the tool
## the action INVOKES. The evidence is PROCESS-TREE-scoped: io-mon reports an
## `mrNonDeterministic` record for any process in the tree. For a compiler the
## two coincide -- the tree under `nim` is nim, gcc and ld, all of it "what nim
## does" -- so `nim`'s blessing is a claim about nim and the action-scoped
## check is sound. For an interpreter they come apart: `bash <script>` emits
## ZERO entropy records of its own and every record belongs to a child the
## SCRIPT chose to run, so an action-scoped blessing on the shell would waive
## strangers. `packages/sh.nim` refuses to carry one for exactly that reason.
##
## THE MECHANISM. `repro_build_engine` resolves each entropy record's
## `MonitorRecord.osPid` against the capture's own `mrProcessExec` records --
## which name every pid's image -- and asks THIS table whether that image's own
## CLI spec blesses it. A blessing then says "this TOOL's randomness is
## benign", which is a claim the tool's author can actually make, instead of
## "randomness anywhere under this action is benign", which is a claim nobody
## can.
##
## WHY THE TABLE IS HERE AND NOT ONLY IN THE CLI SPEC. A CLI spec lives in
## `repro_dsl_stdlib`, is compiled into the RECIPE PROVIDER, and reaches the
## engine only as `BuildAction.nonDeterminism` -- one slot, for the one tool
## the action invokes. The engine grading a capture has no access to the specs
## and no way to ask about a tool the action did not invoke. So the per-image
## half of the blessing is a constant here, in the lowest library both halves
## can see, and `libs/repro_dsl_stdlib/tests/t_entropy_image_blessings.nim`
## asserts entry-for-entry that each image listed below is backed by a real
## `nonDeterminism entropyBlessed` in that tool's own CLI spec, carrying the
## SAME justification text. An entry whose spec stops blessing fails that
## test; the table cannot become a second, independent authority.
##
## WHAT IS DELIBERATELY NOT IN THE TABLE, measured on this host with io-mon
## on the linux-preload-hooks backend, because the next person will meet these
## three before they meet anything else:
##
##   * `uuidgen` -- one `getrandom`, one process, no caller token: a record
##     INDISTINGUISHABLE from `mktemp`'s in every field but the emitting pid.
##     The difference is the claim each tool's author can make. mktemp's bytes
##     name scratch space; uuidgen's bytes ARE the value its caller keeps. If
##     this table ever answers for uuidgen, the mechanism has the same defect
##     as the shell waiver it replaced.
##
##   * `python3` -- one `getrandom` at startup, from CPython itself, and it is
##     the `PYTHONHASHSEED` draw: measured, `python3 -c 'print(1)'` emits one
##     record and `PYTHONHASHSEED=0 python3 -c 'print(1)'` emits NONE. Those
##     bytes seed str/bytes hashing, so they decide set and dict ITERATION
##     ORDER, which routinely reaches a program's output. It is the textbook
##     case of entropy that DOES reach a product, and it must not be blessed.
##     The sound remedy belongs in the recipe, not here: an action that
##     declares `PYTHONHASHSEED=0` removes both the record and the
##     non-determinism it stands for.
##
##   * `nim`, `gcc`, and every other tool an action INVOKES directly. Those
##     are blessed (or not) at ACTION scope through `BuildAction
##     .nonDeterminism`, where the claim covers the whole process tree because
##     the tree is the tool's own. A per-image entry for one of them would say
##     something narrower and untrue -- that a `nim` process running under
##     somebody else's action is vouched for.
##
## ADDING AN ENTRY IS A SOUNDNESS DECISION, NOT A CONVENIENCE. The rule is
## `Monitor-Hook-Shim.md`'s: uncacheable is safe, falsely-cacheable is not. An
## entry must rest on MEASURED domain knowledge about what that tool draws
## randomness FOR, the way `nim`'s does -- never on the inconvenience of the
## signal. And note what an entry does NOT bless: it is scoped to entropy
## (`mrNonDeterministic`). Clock reads (`mrTimeRead`) are a separate signal
## this engine deliberately does not grade at all, for the reason that
## blessing them would mean blessing every program alive.

import std/[options, strutils]

type
  EntropyBlessedTool* = object
    ## One tool whose own CLI spec states that its randomness cannot reach its
    ## output, keyed by the IMAGE NAME an `mrProcessExec` record would carry.
    image*: string
      ## The executable's base name, without any platform suffix: `mktemp`,
      ## `git`. Matched against the base name of the resolved image, with a
      ## trailing `.exe` stripped and the comparison case-insensitive, because
      ## Windows spells the same tool `git.exe`, `GIT.EXE` and `git`.
    spec*: string
      ## The CLI spec that carries the authoritative declaration. Named so a
      ## diagnostic can send an operator to the prose rather than to this list.
    justification*: string
      ## Mirrored VERBATIM from that spec's `nonDeterminism entropyBlessed,
      ## justification = "..."`. The DSL refuses a blessing without one; this
      ## copy exists so the engine's diagnostic can state the reason a record
      ## was excused, and so the correspondence test has something to compare.

const
  MktempEntropyJustification* =
    "GNU coreutils `mktemp` draws randomness for exactly one purpose: the " &
    "X-suffix of the temporary name it creates and prints. That name is a " &
    "handle to scratch space whose whole contract is that it does not " &
    "outlive the caller, so the random bytes designate a LOCATION and never " &
    "the content of a product. Measured with io-mon @87143d62 on the " &
    "linux-preload-hooks backend: across CodeTracer's ten shell gates at " &
    "996f9b12 mktemp accounts for 23 of the 45 mrNonDeterministic records, " &
    "every one path=getrandom, every one emitted in a pid whose " &
    "mrProcessExec names mktemp and whose only writes are the scratch " &
    "directory the gate later removes; not one of those names appears in a " &
    "declared output. This blesses ENTROPY only. It says nothing about a " &
    "recipe that captures the printed name INTO a product -- that is the " &
    "recipe's bug, and a signal that records zero events for a script whose " &
    "whole output is $RANDOM was never what guarded against it."

  GitEntropyJustification* =
    "git draws randomness only to name files it is about to rename away. " &
    "Measured with io-mon @87143d62 on the linux-preload-hooks backend: " &
    "`git init`, `git rev-parse HEAD`, `git log --oneline -1`, `git status " &
    "--porcelain` and `git clone` draw NONE; `git add` draws one record and " &
    "`git add` + `git commit` two, and each record sits in the same pid as " &
    "the creation of .git/index.lock, .git/refs/heads/<branch>.lock and " &
    ".git/objects/XX/tmp_obj_XXXXXX -- lock files and loose-object " &
    "temporaries. Every one of those is renamed or hard-linked to a name git " &
    "computes from CONTENT (the object hash) or fixes by convention (index, " &
    "refs/heads/<branch>), so no random byte survives into an object, a ref " &
    "or the working tree; that git's whole object store is content-addressed " &
    "is what makes the claim checkable rather than a promise. Across " &
    "CodeTracer's ten shell gates at 996f9b12 git accounts for 22 of the 45 " &
    "records, all path=getrandom, all in `git add` / `git commit` pids. " &
    "This blesses ENTROPY only, and the exception is worth naming because it " &
    "is the one people reach for: a commit object's hash depends on its " &
    "author and committer TIMESTAMPS. That is a clock read (mrTimeRead), a " &
    "separate signal this engine does not grade for any tool, and nothing " &
    "here waives it."

  EntropyBlessedTools*: array[2, EntropyBlessedTool] = [
    EntropyBlessedTool(
      image: "mktemp",
      spec: "libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/mktemp.nim",
      justification: MktempEntropyJustification),
    EntropyBlessedTool(
      image: "git",
      spec: "libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/git.nim",
      justification: GitEntropyJustification)
  ]

proc entropyBlessingImageKey*(imagePath: string): string =
  ## The key an image path is matched by: its base name, lower-cased, with a
  ## trailing `.exe` removed.
  ##
  ## BASE NAME AND NOT THE FULL PATH, deliberately. The same tool lives at
  ## `/usr/bin/git`, `~/.nix-profile/bin/git`, `/nix/store/<hash>-git/bin/git`
  ## and `C:\...\PortableGit\bin\git.exe`, and a table of absolute paths would
  ## be a table of this machine's store hashes -- stale on the next nixpkgs
  ## bump, and liable to be "fixed" with a prefix match, which fails OPEN.
  ##
  ## THE COST OF THAT CHOICE, stated rather than hidden: a build that runs
  ## some other program named `git` gets git's blessing. That is the same
  ## trust boundary every tool reference in this engine already sits on -- an
  ## action invoking `nim` inherits `nim`'s blessing from the CLI spec without
  ## the engine hashing the compiler first -- and it is bounded by what a
  ## blessing can do at all, which is to lift one refusal to publish one
  ## action's cache entry.
  var name = imagePath
  for i in countdown(name.high, 0):
    if name[i] in {'/', '\\'}:
      name = name[i + 1 .. ^1]
      break
  name = name.toLowerAscii()
  if name.endsWith(".exe"):
    name = name[0 ..< name.len - 4]
  name

proc entropyBlessedTool*(imagePath: string): Option[EntropyBlessedTool] =
  ## The blessing for a resolved image, or `none` -- which is the answer for
  ## EVERY tool nobody has vouched for, and for the empty string that an
  ## unresolvable pid produces. Failing closed on an unknown emitter is the
  ## whole point: an entropy record whose author cannot be named must not
  ## inherit somebody else's blessing.
  if imagePath.len == 0:
    return none(EntropyBlessedTool)
  let key = entropyBlessingImageKey(imagePath)
  if key.len == 0:
    return none(EntropyBlessedTool)
  for tool in EntropyBlessedTools:
    if tool.image == key:
      return some(tool)
  none(EntropyBlessedTool)
