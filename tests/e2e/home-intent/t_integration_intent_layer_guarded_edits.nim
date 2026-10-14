## Gate: `integration_intent_layer_guarded_edits`.
##
## A compiled profile guards `config:` entries and `resources:` declarations
## with runtime `when <pred>:` chains (`elif` / `else` branches, nesting),
## GM3 of the Gradual-Nix-To-Reprobuild-Migration plan. The structural
## editor (`repro home add/remove/set`) reads the same file through the
## text-level inspector (`loadProfile`), so it must:
##
## * read the chains, with the branch semantics the profile macro gives them
##   (each branch's predicate conjoined with the negation of every earlier
##   one), so the guard walkers select from a parsed profile exactly what the
##   planner selects from the compiled one;
## * leave every guarded element byte-for-byte as it is while editing other
##   entries of the same profile (add / remove of packages, unguarded `set`);
## * create a guarded config entry for `setConfigurable(predicate = ...)`,
##   finding an existing guard by normalized predicate;
## * refuse -- not guess, not drop -- an edit that would overlap a guarded
##   assignment of the same key, an unguarded resource edit whose address is
##   declared only under a guard, and every guard shape it cannot read
##   (compile-time `when defined`, `if` in `config:`, a dangling `elif`,
##   helper calls). A refused edit leaves the file byte-identical.
##
## No mocks: the real parser, editor and walkers on real files in a temp
## directory. The fixtures are inline so each case states the bytes it
## starts from. The CLI and the compiled side of the same contract are
## gated by `tests/e2e/m83/t_e2e_home_set_writes_guarded_config.nim`.

import std/[options, os, strutils, tables, unittest]

import repro_home_intent

const GuardedProfile = """
import repro_profile

profile "guarded":
  activity default:
    git
    ripgrep
    when windows:
      windows-terminal

  config:
    git:
      userName = "Zahary"
      # per-platform line endings
      when windows():
        autocrlf = "true"
      elif macos():
        autocrlf = "input"
      else:
        autocrlf = "false"
    when linux():
      ripgrep:
        smartCase = true
        when arm64():
          threads = 2

  resources:
    fs.userFile common:
      hostFile = "~/.common"
      content = "everywhere"
    when linux:
      fs.userFile platformRc:
        hostFile = "~/.config/linux.conf"
        content = "linux"
    elif macos:
      fs.userFile platformRc:
        hostFile = "~/Library/macos.conf"
        content = "macos"
    else:
      fs.userFile platformRc:
        hostFile = "~/AppData/windows.conf"
        content = "windows"

  hosts:
    "dev-laptop": []
"""

proc tmpProfile(name, content: string): string =
  let dir = getTempDir() / "repro-home-intent-guarded" / name
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  result = dir / "home.nim"
  writeFile(result, content)

proc ctxFor(platform, arch: string): HostContext =
  HostContext(platform: platform, arch: arch, host: "dev-laptop",
    isWsl: false)

proc configFor(path: string; ctx: HostContext): seq[string] =
  ## `<pkg>.<key>=<value>` for every config entry the walkers select on
  ## `ctx`, in declaration order.
  let prof = loadProfile(path)
  let cfg = findConfigBlock(prof)
  if cfg.isNone:
    return
  for pkg in applicableConfigPackages(cfg.get, ctx):
    for entry in applicableConfigEntries(pkg, ctx):
      result.add pkg.configPackageName & "." & entry.configKey & "=" &
        entry.configValueSource

proc resourcesFor(path: string; ctx: HostContext): seq[string] =
  let prof = loadProfile(path)
  let res = findResourcesBlock(prof)
  if res.isNone:
    return
  for entry in applicableResourceEntries(res.get.resourcesEntries, ctx):
    for attr in entry.resourceAttrs:
      if attr.resourceAttrKey == "hostFile":
        result.add entry.resourceAddress & "=" & attr.resourceAttrValueSource

proc section(text, header, nextHeader: string): string =
  ## The bytes from `header` up to (not including) `nextHeader`.
  let a = text.find(header)
  doAssert a >= 0, "missing " & header
  let b = text.find(nextHeader, a + header.len)
  doAssert b > a, "missing " & nextHeader & " after " & header
  text[a ..< b]

let linuxX86 = ctxFor("linux", "x86_64")
let linuxArm = ctxFor("linux", "arm64")
let macArm = ctxFor("macos", "arm64")
let windowsX86 = ctxFor("windows", "x86_64")

suite "intent layer: guarded config and resources under the structural editor":

  test "guard chains read with the profile macro's branch semantics":
    let path = tmpProfile("read", GuardedProfile)
    check configFor(path, linuxX86) == @["git.userName=\"Zahary\"",
      "git.autocrlf=\"false\"", "ripgrep.smartCase=true"]
    check configFor(path, linuxArm) == @["git.userName=\"Zahary\"",
      "git.autocrlf=\"false\"", "ripgrep.smartCase=true",
      "ripgrep.threads=2"]
    check configFor(path, macArm) == @["git.userName=\"Zahary\"",
      "git.autocrlf=\"input\""]
    check configFor(path, windowsX86) == @["git.userName=\"Zahary\"",
      "git.autocrlf=\"true\""]
    check resourcesFor(path, linuxX86) == @["common=\"~/.common\"",
      "platformRc=\"~/.config/linux.conf\""]
    check resourcesFor(path, macArm) == @["common=\"~/.common\"",
      "platformRc=\"~/Library/macos.conf\""]
    check resourcesFor(path, windowsX86) == @["common=\"~/.common\"",
      "platformRc=\"~/AppData/windows.conf\""]
    # The effective-config resolver `repro home set` pre-validates with
    # walks the same guards (ripgrep's guarded package block included).
    let eff = resolveEffectiveConfig(loadProfile(path), "dev-laptop",
      linuxArm)
    check eff.overrides["git"]["autocrlf"] == "\"false\""
    check eff.overrides["ripgrep"]["threads"] == "2"
    let effMac = resolveEffectiveConfig(loadProfile(path), "dev-laptop",
      macArm)
    check "ripgrep" notin effMac.overrides
    check "ripgrep" notin effMac.inertOverrides

  test "the effective config is last-write-wins per key across package blocks":
    # Configurable-System.md §Priorities And Contributions: scalars resolve
    # last-write-wins, per key. A second `git:` block (here inside a guard
    # chain) adds to and overrides the first block's keys; it must not
    # replace the first block's table wholesale.
    let path = tmpProfile("last-wins", """
import repro_profile

profile "lastWins":
  activity default:
    git

  config:
    git:
      userName = "first"
      editor = "nano"
      when linux():
        userName = "second"
    when linux():
      git:
        pager = "less"
""")
    let prof = loadProfile(path)
    let eff = resolveEffectiveConfig(prof, "dev-laptop", linuxX86)
    check eff.overrides["git"]["userName"] == "\"second\""
    check eff.overrides["git"]["editor"] == "\"nano\""
    check eff.overrides["git"]["pager"] == "\"less\""
    let effMac = resolveEffectiveConfig(prof, "dev-laptop", macArm)
    check effMac.overrides["git"]["userName"] == "\"first\""
    check "pager" notin effMac.overrides["git"]

  test "add then remove a package leaves guarded config and resources byte-identical":
    let path = tmpProfile("add-remove", GuardedProfile)
    addPackageReference(path, "fd")
    let afterAdd = readFile(path)
    check "    fd\n" in afterAdd
    check section(afterAdd, "  config:", "  hosts:") ==
      section(GuardedProfile, "  config:", "  hosts:")
    removePackageReference(path, "fd")
    check readFile(path) == GuardedProfile
    # A guarded package reference elsewhere does not disturb the chains.
    addPackageReference(path, "wsl-tools", predicate = "windows")
    check section(readFile(path), "  config:", "  hosts:") ==
      section(GuardedProfile, "  config:", "  hosts:")
    removePackageReference(path, "wsl-tools", predicate = "windows")
    check readFile(path) == GuardedProfile

  test "an unguarded set of another key keeps every guarded entry":
    let path = tmpProfile("set-other-key", GuardedProfile)
    setConfigurable(path, "git.userEmail", "z@example.com", nil)
    let after = readFile(path)
    # The new line is the only change, and it follows the chain at the
    # package block's entry indent (outside every branch).
    check after == GuardedProfile.replace(
      "        autocrlf = \"false\"\n",
      "        autocrlf = \"false\"\n      userEmail = \"z@example.com\"\n")
    for ctx in [linuxX86, macArm, windowsX86]:
      check "git.userEmail=\"z@example.com\"" in configFor(path, ctx)
    check "git.autocrlf=\"input\"" in configFor(path, macArm)
    check "git.autocrlf=\"true\"" in configFor(path, windowsX86)
    # Updating an existing unguarded entry is in place.
    setConfigurable(path, "git.userName", "Z", nil)
    check readFile(path) == after.replace("userName = \"Zahary\"",
      "userName = \"Z\"")

  test "set with a predicate creates a guarded entry and finds it again by normalized predicate":
    let path = tmpProfile("set-guarded-new", GuardedProfile)
    setConfigurable(path, "git.pager", "less", nil,
      predicate = "linux and arm64")
    let after = readFile(path)
    check after == GuardedProfile.replace(
      "        autocrlf = \"false\"\n",
      "        autocrlf = \"false\"\n      when arm64 and linux:\n" &
      "        pager = \"less\"\n")
    check "git.pager=\"less\"" in configFor(path, linuxArm)
    check "git.pager=\"less\"" notin configFor(path, linuxX86).join(" ")
    check "git.pager=\"less\"" notin configFor(path, macArm).join(" ")
    # A second set with the operands swapped lands in the same block.
    setConfigurable(path, "git.pager", "most", nil,
      predicate = "arm64 and linux")
    check readFile(path) == after.replace("pager = \"less\"",
      "pager = \"most\"")
    check readFile(path).count("when arm64 and linux:") == 1

  test "set with a predicate appends into, or updates within, an existing guard":
    let path = tmpProfile("set-guarded-existing", GuardedProfile)
    # `windows` normalizes like the chain head `when windows():`.
    setConfigurable(path, "git.editor", "notepad", nil, predicate = "windows")
    let after = readFile(path)
    check after == GuardedProfile.replace(
      "        autocrlf = \"true\"\n",
      "        autocrlf = \"true\"\n        editor = \"notepad\"\n")
    check "git.editor=\"notepad\"" in configFor(path, windowsX86)
    check "git.editor=\"notepad\"" notin configFor(path, macArm).join(" ")
    setConfigurable(path, "git.autocrlf", "crlf", nil, predicate = "windows")
    check readFile(path) == after.replace("autocrlf = \"true\"",
      "autocrlf = \"crlf\"")
    check "git.autocrlf=\"crlf\"" in configFor(path, windowsX86)
    check "git.autocrlf=\"input\"" in configFor(path, macArm)

  test "a new assignment overlapping a guarded one is refused, file untouched":
    let path = tmpProfile("refuse-overlap", GuardedProfile)
    # Unguarded, after the chain: it would override every branch.
    expect EOverlappingAssignment:
      setConfigurable(path, "git.autocrlf", "false", nil)
    check readFile(path) == GuardedProfile
    # A new unguarded `ripgrep:` block after the guarded one would override
    # `smartCase` on Linux.
    try:
      setConfigurable(path, "ripgrep.smartCase", "false", nil)
      check false
    except EOverlappingAssignment as e:
      check e.target == "ripgrep.smartCase"
      check e.sites.len == 1
      check e.sites[0].endsWith(":22 (under `when linux():`)")
      check "would override a guarded assignment" in e.msg
    check readFile(path) == GuardedProfile
    # A new guard after the chain would shadow its `else:` branch on Linux.
    expect EOverlappingAssignment:
      setConfigurable(path, "git.autocrlf", "lf", nil, predicate = "linux")
    check readFile(path) == GuardedProfile

  test "an unguarded resource edit of a guarded-only address is refused; an unguarded one is edited in place":
    let path = tmpProfile("resource-edit", GuardedProfile)
    try:
      setResource(path, "fs.userFile", "platformRc", "content", "x")
      check false
    except EGuardedTarget as e:
      check e.target == "platformRc"
      check e.sites.len == 3
    check readFile(path) == GuardedProfile
    setResource(path, "fs.userFile", "common", "content", "changed")
    check readFile(path) == GuardedProfile.replace("content = \"everywhere\"",
      "content = \"changed\"")

  test "guard shapes the editor cannot read are refused with a diagnostic naming them":
    proc refusal(name, content: string): string =
      let path = tmpProfile(name, content)
      try:
        addPackageReference(path, "fd")
      except EUnstructured as e:
        check readFile(path) == content
        return e.seen & " | " & e.expected
      check false
      ""
    let compileTime = refusal("defined", GuardedProfile.replace(
      "      when windows():\n", "      when defined(windows):\n"))
    check "compile-time `when defined(windows):`" in compileTime
    check "not machine-editable" in compileTime
    let ifInConfig = refusal("if", GuardedProfile.replace(
      "    when linux():\n      ripgrep:", "    if linux():\n      ripgrep:"))
    check "`if linux():` in `config:`" in ifInConfig
    check "accepts only `when` chains" in ifInConfig
    let dangling = refusal("dangling-elif", GuardedProfile.replace(
      "      userName = \"Zahary\"\n",
      "      userName = \"Zahary\"\n      elif linux():\n        pager = \"x\"\n"))
    check "`elif` without a preceding `when <pred>:` branch" in dangling
    let helperInConfig = refusal("helper-config", GuardedProfile.replace(
      "    when linux():\n      ripgrep:",
      "    gitPlatformConfig()\n    when linux():\n      ripgrep:"))
    check "gitPlatformConfig()" in helperInConfig
    check "`<package>:` header inside `config:`" in helperInConfig
    let guardedHelper = refusal("helper-resources", GuardedProfile.replace(
      "    when linux:\n      fs.userFile platformRc:",
      "    guarded(targetResources, linux()):\n" &
      "      fs.userFile platformRc:"))
    check "guarded(targetResources," in guardedHelper
