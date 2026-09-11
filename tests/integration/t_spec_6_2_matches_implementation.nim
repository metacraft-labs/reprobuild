## The attestation activity's reference snippet and the module it
## describes are the same thing — checked by COMPILING the snippet and
## comparing what it builds against what the module builds.
##
## ## Why this gate exists at all
##
## The snippet in that section used to describe an activity declaration
## written in forms the macro does not parse: a `config:` section, an
## `@variant` annotation, a `validate:` rule, per-unit `enable:` and
## `wantedBy:` settings. Every one of them is a compile error or a silent
## misreading. Somebody eventually copies a declaration out of a
## reference document, finds it does not work, and spends the afternoon
## establishing what the language actually is. That has now happened
## more than once, which is why the contract is machine-checked rather
## than reviewed.
##
## ## Why a text comparison would not do
##
## "The document mentions `attestationActivity`" is satisfied by the word
## appearing anywhere, including in a sentence saying it does not exist.
## Worse, the contract here IS a fenced code block, so the usual
## protection — ignore anything inside a fence, it is only an example —
## inverts: the fence is the thing being asserted about. That removes the
## cheapest defence and leaves the failure modes a documentation check
## keeps running into:
##
##   * the assertion satisfied by a DIFFERENT SECTION of the same
##     document — so the section is located by its heading, a second
##     heading with the same text is REFUSED, and nothing outside the
##     section's line range is read;
##   * the assertion satisfied by a SECOND block beside the first, with
##     the lie whichever one the parser happens to take — so more than
##     one `nim` block inside the section is REFUSED rather than merged
##     or first-wins;
##   * a heading quoted inside an unrelated fence opening or closing a
##     section it has nothing to do with — so fence state is tracked
##     across the WHOLE document and a line inside a fence is never read
##     as a heading;
##   * the section's END dissolved rather than its start moved — demote
##     every heading below it and the section runs to the last line of
##     the document, at which point "the section says X" is satisfied by
##     any appendix. So a section that is never closed by a heading at
##     its own level or shallower is REFUSED, which turns that edit from
##     a silent widening into a failure.
##
## And then the load-bearing assertion is not textual at all: the
## extracted snippet is WRITTEN OUT AND COMPILED against the shipped
## module, run, and what it produces is compared to what the module
## produces. A snippet naming a form that does not exist does not
## compile; a snippet whose settings the rule refuses does not run.
##
## ## Comparing the activity alone was not enough, and that was measured
##
## The first version of this gate compared only the `SystemActivitySpec`
## the snippet builds. That spec carries a name, a package list and a
## unit list — and NO tier, no listen address, no layout. So every
## setting the snippet exists to show was invisible to the comparison:
## changing the documented tier to the one with no root of trust left
## the gate green. It was found by mutating the document and watching
## nothing happen, which is the only way this class of defect is ever
## found.
##
## The snippet therefore exports its SETTINGS as well as its activity,
## and three further assertions read them: the documented example must
## be an attested configuration rather than the exempt one, its layout
## must be one the module considers attestable, and every other setting
## it writes out must equal the module's own default — the last computed
## inside the snippet's process against the module's constructor, since
## that is the only place the defaults exist.
##
## ## What is derived rather than listed
##
## The set of settings the snippet must mention is read off
## `AttestationActivityConfig` with `fieldPairs`, not written down here.
## A field added to the config and left out of the document reddens this
## gate without anyone remembering to update a list — which is the only
## version of "the document is complete" that stays true.
##
## ## The sibling checkout
##
## The reference document is in the specification checkout beside this
## repository. When that checkout is absent entirely the document cases
## skip; when it is present the document must exist and must agree, so
## deleting the page is not a way to switch the assertion off. The
## structural cases that need no document run unconditionally.
##
## ## Mocking
##
## None. The document is read from disk as it ships and the snippet is
## compiled by a real `nim c`.

import std/[os, osproc, strutils, tables, tempfiles, unittest]

import repro_dsl_stdlib/packages/system/attestation
import repro_profile

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir

const
  SpecRelPath = ".." / "reprobuild-specs" / "ReproOS-Remote-Attestation.md"
  SectionHeading = "### 6.2 Activity module"
  FenceLanguage = "nim"

proc findUpFile(startDir, rel: string): string =
  var dir = startDir
  for _ in 0 .. 8:
    let candidate = dir / rel
    if fileExists(candidate): return candidate
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir: break
    dir = parent
  ""

proc findUpDir(startDir, rel: string): string =
  var dir = startDir
  for _ in 0 .. 8:
    let candidate = dir / rel
    if dirExists(candidate): return candidate
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir: break
    dir = parent
  ""

type SectionParts* = object
  prose*: string    ## the section's lines that are NOT inside a fence
  code*: string     ## the one `nim` fenced block in the section

proc withoutNimComments*(src: string): string =
  ## Nim source with `#` comments removed, so a claim about what the
  ## snippet DOES cannot be satisfied by a line describing what it does.
  ## String literals are left alone — a `#` inside one is not a comment.
  ##
  ## Deliberately a copy of the same proc in
  ## `t_activity_validate_gate`, which strips the module for the same
  ## reason: the two gates share no other code and a helper module
  ## imported for twenty lines would tie a document check to a harness
  ## that spawns the CLI.
  var lines: seq[string]
  for raw in src.splitLines:
    var inStr = false
    var cut = raw.len
    var i = 0
    while i < raw.len:
      let c = raw[i]
      if c == '\\' and inStr:
        i += 2
        continue
      if c == '"':
        inStr = not inStr
      elif c == '#' and not inStr:
        cut = i
        break
      inc i
    lines.add raw[0 ..< cut]
  lines.join("\n")

proc sectionParts*(md: string): SectionParts =
  ## Split the document's `SectionHeading` section into its prose and its
  ## single `nim` code block.
  ##
  ## Fence state is tracked across the whole document, before any heading
  ## is considered, so a fence opened earlier swallows a heading rather
  ## than letting it open a section. The section ends at the next heading
  ## of the SAME OR SHALLOWER level that is not inside a fence; a deeper
  ## heading (`#### 6.2.1 …`) stays inside, because it is part of this
  ## section rather than the next one.
  var headings = 0
  var inSection = false
  var inFence = false
  var fenceLang = ""
  var codeBlocks = 0
  var proseLines: seq[string]
  var codeLines: seq[string]
  for raw in md.splitLines:
    let stripped = raw.strip()
    if stripped.startsWith("```"):
      if inFence:
        inFence = false
        fenceLang = ""
      else:
        inFence = true
        fenceLang = stripped[3 .. ^1].strip()
        if inSection and fenceLang == FenceLanguage:
          inc codeBlocks
          doAssert codeBlocks == 1,
            "the section opens a second `" & FenceLanguage & "` block; " &
              "a reader and this parser would not have to be looking at " &
              "the same declaration"
      continue
    if inFence:
      if inSection and fenceLang == FenceLanguage:
        codeLines.add raw
      continue
    if stripped.startsWith("#"):
      if stripped == SectionHeading:
        inc headings
        doAssert headings == 1,
          "the document opens a second `" & SectionHeading & "` section; " &
            "a document with two of them can show a reader one answer " &
            "and this parser another"
        inSection = true
        continue
      if inSection:
        # A deeper heading belongs to this section; anything at the same
        # level or shallower ends it.
        var level = 0
        while level < stripped.len and stripped[level] == '#': inc level
        var ownLevel = 0
        while ownLevel < SectionHeading.len and SectionHeading[ownLevel] == '#':
          inc ownLevel
        if level <= ownLevel:
          inSection = false
        else:
          proseLines.add raw
        continue
      continue
    if inSection:
      proseLines.add raw
  # The section has to be CLOSED by a heading, not by the end of the
  # file. Demoting every heading below it is a one-character edit per
  # line that leaves the document looking normal and makes the section
  # run to the last line, so "the section states X" becomes satisfiable
  # by an appendix. Measured: with `### 6.3` demoted, the retraction
  # statements moved to the foot of the document kept this gate green.
  if headings == 1:
    doAssert not inSection,
      "the `" & SectionHeading & "` section is never closed: no later " &
        "heading is at its level or shallower, so it runs to the end of " &
        "the document and every line below it counts as its prose"
  result.prose = proseLines.join("\n")
  result.code = codeLines.join("\n")

proc configFieldNames(): seq[string] =
  ## The settings surface, read off the type rather than listed.
  var probe = attestationConfig("uefi-attested")
  for name, _ in probe.fieldPairs:
    result.add name

let thisDir = currentSourcePath().parentDir
let specPath = findUpFile(thisDir, SpecRelPath)
let specDir = findUpDir(thisDir, ".." / "reprobuild-specs")

suite "the reference snippet and the shipped activity agree":

  test "the section exists and carries exactly one nim block":
    if specDir.len == 0:
      skip()
    else:
      check specPath.len > 0
      let parts = sectionParts(readFile(specPath))
      check parts.code.strip().len > 0
      check parts.prose.strip().len > 0
      # The snippet is a module, not a fragment: it imports what it uses.
      check "import repro_dsl_stdlib/packages/system/attestation" in parts.code
      # The settings the snippet EXPORTS have to be the settings the
      # activity was built from. This one check is textual and cannot be
      # anything else: a `SystemActivitySpec` records none of its
      # settings, so a snippet that reported one configuration and built
      # the activity from another would produce byte-identical output and
      # the comparison below could not tell. Asserting the call instead
      # is narrow, but it is exact.
      #
      # Read off the snippet with its COMMENTS STRIPPED. The call text
      # parked in a `#` line while the activity is built from other
      # settings is the same lie one indirection further out, and it was
      # green before this.
      check "attestationActivity(attestationSettings)" in
        withoutNimComments(parts.code)

  test "the snippet compiles, and builds the activity the module builds":
    if specDir.len == 0:
      skip()
    elif not (defined(linux) or defined(macosx)):
      skip()
    else:
      let parts = sectionParts(readFile(specPath))
      let tmp = createTempDir("spec-6-2-snippet-", "")
      defer:
        try: removeDir(tmp)
        except CatchableError: discard
      # The snippet verbatim, plus a driver that reads what it exported.
      # The snippet itself is NOT edited — a gate that had to patch the
      # document's code to make it build would be proving something
      # about the patch.
      writeFile(tmp / "spec_snippet.nim", parts.code & "\n")
      # The driver reports FOUR facts about what the snippet built, not
      # one. The activity alone is not enough and this gate learned that
      # the hard way: a `SystemActivitySpec` carries no tier, no listen
      # address and no layout, so comparing only the activity is blind to
      # every setting the snippet actually shows — the document could
      # advertise the tier with no root of trust and the comparison would
      # not move. The settings the snippet built are reported separately,
      # and `defaultsMatch` is computed INSIDE the snippet's own process
      # against the module's constructor, which is the only place the
      # defaults exist.
      writeFile(tmp / "driver.nim", """
import repro_dsl_stdlib/packages/system/attestation
import repro_profile
import ./spec_snippet

let shown = spec_snippet.attestationSettings
echo "activity=" & emitSystemActivityJson(spec_snippet.attestationActivitySpec)
echo "tier=" & $shown.tier
echo "imageLayout=" & shown.imageLayout
echo "defaultsMatch=" &
  $(shown == attestationConfig(shown.imageLayout, tier = shown.tier))
""")
      writeFile(tmp / "config.nims",
        "include \"" & (RepoRoot / "config.nims").replace('\\', '/') & "\"\n")
      # A missing compiler is a LOUD failure and not a skip: this suite
      # is itself Nim, so `nim` being absent means the environment is
      # broken rather than merely different, and a skip here would hide
      # the one assertion the gate is named for.
      let nimExe = findExe("nim")
      doAssert nimExe.len > 0,
        "nim is not on PATH; this gate compiles the document's snippet " &
        "and cannot report anything without a compiler"
      var cmd = quoteShell(nimExe) & " c --hints:off --warnings:off"
      for kind, path in walkDir(RepoRoot / "libs"):
        if kind notin {pcDir, pcLinkToDir}: continue
        if dirExists(path / "src"):
          cmd.add " --path:" & quoteShell(path / "src")
      cmd.add " --out:" & quoteShell(tmp / "driver")
      cmd.add " " & quoteShell(tmp / "driver.nim")
      let (compileOut, compileCode) = execCmdEx(cmd)
      # A snippet written in forms the macro does not parse fails HERE,
      # which is the whole reason this gate compiles rather than reads.
      check compileCode == 0
      if compileCode != 0:
        echo compileOut

      # Running it is half the assertion: the snippet calls the
      # validator, so a settings pairing the rule refuses raises here and
      # the document's own example fails to run.
      let (runOut, runCode) = execCmdEx(quoteShell(tmp / "driver"))
      check runCode == 0
      var facts: Table[string, string]
      for line in runOut.splitLines:
        let idx = line.find('=')
        if idx > 0: facts[line[0 ..< idx]] = line[idx + 1 .. ^1].strip()
      for name in ["activity", "tier", "imageLayout", "defaultsMatch"]:
        check name in facts

      # BYTE EQUALITY against what the module produces. Not "the names
      # appear" — the whole activity.
      check facts.getOrDefault("activity") ==
        emitSystemActivityJson(attestationActivity(
          attestationConfig("uefi-attested", tier = atTpm)))

      # The activity is the attestation one, so an equality between two
      # empty specs cannot pass this.
      let spec = parseSystemActivityJson(facts.getOrDefault("activity"))
      check spec.name == ActivityName
      check spec.systemPackages == @[AgentPackage]
      check spec.systemServices == @[UnitName]

      # THE SETTINGS THE SNIPPET SHOWS. The activity above carries none
      # of them, so without these three the document could change every
      # value in its own example and nothing would move.
      #
      # The example must be an ATTESTED configuration — a tier with a
      # root of trust, on a layout that can carry a measurement. An
      # example built on `mock` would illustrate the one case the rule
      # exempts, which is the opposite of what the section is for.
      check facts.getOrDefault("tier") != $atMock
      check facts.getOrDefault("imageLayout") in AttestableImageLayouts
      # And every OTHER setting it writes out is the module's own
      # default, so the page cannot teach a value the module does not
      # have. Computed against the module's constructor inside the
      # snippet's process, where the defaults live.
      check facts.getOrDefault("defaultsMatch") == "true"

  test "every setting the config carries is named in the snippet":
    if specDir.len == 0:
      skip()
    else:
      let parts = sectionParts(readFile(specPath))
      let fields = configFieldNames()
      # Derived from the type: a field added and left undocumented
      # reddens without anyone updating a list here.
      check fields.len > 0
      for name in fields:
        check name in parts.code

  test "the snippet uses no form the activity macro cannot parse":
    if specDir.len == 0:
      skip()
    else:
      # Secondary to the compile above, which is structural. This one
      # names the specific forms the section's own subsection says do
      # not exist, so a reader diffing the document sees why.
      let parts = sectionParts(readFile(specPath))
      for absent in ["config:", "@variant", "validate:", "wantedBy:",
                     "enable:"]:
        check absent notin parts.code

  test "the prose names the mechanism that actually enforces the rule":
    if specDir.len == 0:
      skip()
    else:
      let parts = sectionParts(readFile(specPath))
      let moduleSrc = readFile(RepoRoot / "libs" / "repro_dsl_stdlib" /
        "src" / "repro_dsl_stdlib" / "packages" / "system" /
        "attestation.nim")
      # Each name the prose gives has to be a name the module really
      # has, so a rename on either side reddens rather than leaving the
      # document describing a proc nobody can find.
      for name in ["validateAttestationConfig", "EConfigViolation",
                   "attestationActivity", "attestationConfig"]:
        check name in parts.prose
        check name in moduleSrc
      # The rule itself, and where it bites.
      check "uefi-attested" in parts.prose
      check "repro infra plan" in parts.prose
      # THE RETRACTION, per form. A document that quietly dropped the
      # declaration it used to show would leave every reader who copied
      # it with no way to find out what happened — so the section has to
      # say, of each form it used to show, that the form does not exist.
      #
      # Asserting the bare token ("@variant" appears somewhere in the
      # prose) was the first version of this and it was too weak: the
      # word occurs in several sentences, so paraphrasing any one of them
      # left the check green. The phrases below are the statements
      # themselves, one per retired form.
      for statement in ["no `config:` section", "no `@variant` annotation",
                        "no `validate:` section"]:
        check statement in parts.prose

suite "the section parser cannot be satisfied by the wrong text":

  # Driven on documents built in memory, so the protection holds in
  # every environment rather than only where the sibling checkout is.

  const Body = "let attestation* = attestationActivity(x)"

  test "a block in another section is not read":
    let doc = "### 6.2 Activity module\n\nprose\n\n" &
      "### 6.3 API\n\n```nim\n" & Body & "\n```\n"
    let parts = sectionParts(doc)
    check parts.code == ""
    check "prose" in parts.prose

  test "a deeper heading stays inside the section":
    let doc = "### 6.2 Activity module\n\nprose\n\n" &
      "#### 6.2.1 Why\n\nmore prose\n\n```nim\n" & Body & "\n```\n" &
      "### 6.3 API\n\nelsewhere\n"
    let parts = sectionParts(doc)
    check parts.code.strip() == Body
    check "more prose" in parts.prose
    check "elsewhere" notin parts.prose

  test "a fence opened before the heading swallows it":
    let doc = "## 6 Agent\n\n```text\n### 6.2 Activity module\n" &
      "```\n\nafterwards\n"
    let parts = sectionParts(doc)
    check parts.code == ""
    check parts.prose == ""

  test "a second section with the same heading is refused":
    let doc = "### 6.2 Activity module\n\na\n\n" &
      "### 6.2 Activity module\n\nb\n"
    expect AssertionDefect:
      discard sectionParts(doc)

  test "a second nim block inside the section is refused":
    let doc = "### 6.2 Activity module\n\n```nim\n" & Body & "\n```\n\n" &
      "```nim\nlet attestation* = somethingElse()\n```\n"
    expect AssertionDefect:
      discard sectionParts(doc)

  test "a block in another language is not the contract":
    let doc = "### 6.2 Activity module\n\n```toml\ntier = \"cvm\"\n```\n" &
      "\n### 6.3 API\n"
    let parts = sectionParts(doc)
    check parts.code == ""

  test "a section that runs to the end of the document is refused":
    # Demote every heading below §6.2 and the section swallows the rest
    # of the file, so an appendix satisfies "the section states X". The
    # refusal is what stops that from being a silent widening.
    let doc = "### 6.2 Activity module\n\nprose\n\n" &
      "#### 6.2.1 Why\n\nmore\n\n##### Appendix\n\nanything at all\n"
    expect AssertionDefect:
      discard sectionParts(doc)
    # ... and the SAME document closed by a heading at §6.2's own level
    # parses, so the refusal is about the missing close and not about
    # appendices.
    let closed = doc & "\n### 6.3 API\n\nelsewhere\n"
    let parts = sectionParts(closed)
    check "anything at all" in parts.prose
    check "elsewhere" notin parts.prose

  test "the required call cannot be satisfied by a comment":
    # `withoutNimComments` is what makes the one textual assertion in
    # this gate exact. Without it the snippet can park the call in a
    # comment and build the activity from settings it does not export.
    let lying = "let attestationSettings* = attestationConfig(\"x\")\n" &
      "# attestationActivity(attestationSettings)\n" &
      "let attestationActivitySpec* = attestationActivity(other)\n"
    check "attestationActivity(attestationSettings)" in lying
    check "attestationActivity(attestationSettings)" notin
      withoutNimComments(lying)
    # A `#` inside a string literal is not a comment and must survive.
    check "a#b" in withoutNimComments("let s = \"a#b\"  # trailing\n")
    check "trailing" notin withoutNimComments("let s = \"a#b\"  # trailing\n")

  test "prose is the section's uncoded lines and nothing else":
    let doc = "### 6.1 Package\n\nnot this\n\n" &
      "### 6.2 Activity module\n\nthis\n\n```nim\n" & Body & "\n```\n" &
      "and this\n\n### 6.3 API\n\nnor this\n"
    let parts = sectionParts(doc)
    check "this" in parts.prose
    check "and this" in parts.prose
    check "not this" notin parts.prose
    check "nor this" notin parts.prose
    check Body notin parts.prose
