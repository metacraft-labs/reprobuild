## Smoke test for the M60 home profile intent layer. Verifies the
## parser, predicate normalizer, structural editor, and effective-
## config resolver compile and produce the expected behavior on a
## handful of small fixtures. The real M60 gates live under
## `tests/e2e/home-intent/`.

import std/[options, os, sets, strutils, tables, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_home_intent
import repro_profile/[types, resources, resource_rows, emit]

const SampleProfile = """
import repro/profile

profile "zahary":
  activity default:
    neovim
    tmux
    when windows:
      windows-terminal

  activity develop_software:
    git
    gh

  config:
    git:
      userName = "Zahary"

  hosts:
    "dev-laptop": [develop_software]
"""

proc writeSample(dir: string): string =
  result = dir / "repro-home-smoke-profile.nim"
  writeFile(extendedPath(result), SampleProfile)

suite "Home-intent smoke":

  test "parse recognized profile shape":
    let dir = createTempDir("repro-home-smoke-", "")
    defer: removeDir(dir)
    let path = writeSample(dir)
    let prof = loadProfile(path)
    check prof.root.kind == nkProfileRoot
    check prof.root.name == "zahary"
    check prof.root.children.len == 4
    let act = findActivity(prof, "default")
    check act.isSome
    check act.get.activityChildren.len == 3  # neovim, tmux, when block

  test "hosts block form: the system key is read and validated":
    # The text form of what the `profile` macro accepts
    # (`repro_profile/host_system`): `managedElsewhere`, optionally with a
    # one-line string pointer and a trailing comment; `addOn`; and the
    # add-on block form, indented or inline; anything else is refused with
    # the host named.
    let dir = createTempDir("repro-home-smoke-hosts-system-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    proc withHosts(entries: string): string =
      "import repro/profile\n\nprofile \"x\":\n  activity default:\n" &
        "    neovim\n\n  hosts:\n" & entries
    writeFile(extendedPath(path), withHosts(
      "    \"plain\": [default]\n" &
      "    \"infra\":\n" &
      "      activities: [default]\n" &
      "      system: managedElsewhere(\"example-org/\\\"infra\\\"\")  # c\n" &
      "    \"distro\":\n" &
      "      system: managedElsewhere # no pointer\n" &
      "    \"rpi\":\n" &
      "      activities: [default]\n" &
      "      system: addOn  # short form\n" &
      "    \"validator\":\n" &
      "      system:\n" &
      "        mode: addOn\n" &
      "        activities: [ethereum_validator,\n" &
      "                     host_baseline]  # spans lines\n" &
      "      activities: [default]\n" &
      "    \"inline\":\n" &
      "      system: {mode: addOn, activities: [a, b]} # inline\n" &
      "    \"fullshort\":\n" &
      "      system: full\n" &
      "    \"fullblock\":\n" &
      "      system: {mode: full, activities: [web]}\n"))
    let hostsOpt = findHostsBlock(loadProfile(path))
    require hostsOpt.isSome
    var seen: Table[string, (bool, HostSystemDecl)]
    var acts: Table[string, seq[string]]
    for e in hostsOpt.get.hostsEntries:
      seen[e.hostName] = (e.hostSystemDeclared, e.hostSystem)
      acts[e.hostName] = e.hostActivities
    check seen["plain"] == (false, HostSystemDecl())
    check seen["infra"] == (true, HostSystemDecl(mode: hsmManagedElsewhere,
      managedBy: "example-org/\"infra\""))
    check seen["distro"] == (true, HostSystemDecl(mode: hsmManagedElsewhere))
    check seen["rpi"] == (true, HostSystemDecl(mode: hsmAddOn))
    check seen["validator"] == (true, HostSystemDecl(mode: hsmAddOn,
      activities: @["ethereum_validator", "host_baseline"]))
    check acts["validator"] == @["default"]
    check seen["inline"] == (true, HostSystemDecl(mode: hsmAddOn,
      activities: @["a", "b"]))
    check seen["fullshort"] == (true, HostSystemDecl(mode: hsmFull))
    check seen["fullblock"] == (true, HostSystemDecl(mode: hsmFull,
      activities: @["web"]))
    for bad in [
        "    \"h\":\n      system: managedSomewhere\n",
        "    \"h\":\n      system: managedElsewhere(infra)\n",
        "    \"h\":\n      system: managedElsewhere(\"   \")\n",
        "    \"h\":\n      system: managedElsewhere(\"x\n",
        "    \"h\":\n      system: managedElsewhere(\"x\") extra\n",
        "    \"h\":\n      system: managedElsewhere\n      system: managedElsewhere\n",
        "    \"h\":\n      system: addOn(\"x\")\n",
        "    \"h\":\n      system: {mode: addOn}\n",
        "    \"h\":\n      system: {mode: addOn, activities: []}\n",
        "    \"h\":\n      system: {mode: addOn, activities: [default]}\n",
        "    \"h\":\n      system: {mode: addOn, activities: [a, a]}\n",
        "    \"h\":\n      system: {mode: managedElsewhere, activities: [a]}\n",
        "    \"h\":\n      system: {mode: nixos, activities: [a]}\n",
        "    \"h\":\n      system: {mode: full, activities: []}\n",
        "    \"h\":\n      system: {mode: full, activities: [default]}\n",
        "    \"h\":\n      system: full(\"x\")\n",
        "    \"h\":\n      system: {activities: [a]}\n",
        "    \"h\":\n      system: {mode: addOn, activities: [a]\n",
        "    \"h\":\n      system: {mode: addOn, activities: [a], extra: 1}\n",
        "    \"h\":\n      system:\n        mode: addOn\n",
        "    \"h\":\n      system:\n        mode: addOn\n        mode: addOn\n        activities: [a]\n",
        "    \"h\":\n      system:\n        mode: addOn\n          activities: [a]\n",
        "    \"h\":\n      system:\n"]:
      writeFile(extendedPath(path), withHosts(bad))
      try:
        discard loadProfile(path)
        checkpoint "accepted: " & bad
        check false
      except EUnstructured as e:
        check "\"h\"" in e.msg

  test "rejects unrecognized top-level form":
    let bad = """
import repro/profile

profile "x":
  activity default:
    neovim

  packages:
    - extra
"""
    let dir = createTempDir("repro-home-smoke-bad-toplevel-", "")
    defer: removeDir(dir)
    let badPath = dir / "repro-home-smoke-bad-toplevel.nim"
    writeFile(extendedPath(badPath), bad)
    expect EUnstructured:
      discard loadProfile(badPath)

  test "rejects runtime control flow inside activity body":
    let bad = """
import repro/profile

profile "x":
  activity default:
    for pkg in @["a", "b"]:
      pkg
"""
    let dir = createTempDir("repro-home-smoke-bad-for-", "")
    defer: removeDir(dir)
    let badPath = dir / "repro-home-smoke-bad-for.nim"
    writeFile(extendedPath(badPath), bad)
    expect EUnstructured:
      discard loadProfile(badPath)

  test "predicate canonicalize: commutative ordering":
    check canonicalize("windows and arm64") == "arm64 and windows"
    check canonicalize("arm64 and windows") == "arm64 and windows"
    check canonicalize("WINDOWS and ARM64") == "arm64 and windows"
    check canonicalize("(windows) and (arm64)") == "arm64 and windows"

  test "predicate canonicalize: nested or/and":
    check canonicalize("a or b or c") ==
          canonicalize("c or b or a")
    check canonicalize("not (windows or macos)") ==
          "not (macos or windows)"

  test "predicate evaluates host facts":
    let ctx = HostContext(platform: "windows", arch: "arm64",
      host: "dev-laptop")
    let ast = parsePredicate("", "windows and arm64", 0)
    check evaluateBool(ast, ctx)
    check not evaluateBool(parsePredicate("", "macos", 0), ctx)
    check evaluateBool(parsePredicate("", "host == \"dev-laptop\"", 0), ctx)
    check evaluateBool(
      parsePredicate("", "host in [\"a\", \"dev-laptop\"]", 0), ctx)

  test "round-trip: add then remove restores byte-equal file":
    let dir = createTempDir("repro-home-smoke-roundtrip-", "")
    defer: removeDir(dir)
    let path = writeSample(dir)
    let original = readFile(extendedPath(path))
    addPackageReference(path, "ripgrep", activity = "default")
    let added = readFile(extendedPath(path))
    check added != original
    check "ripgrep" in added
    removePackageReference(path, "ripgrep", activity = "default")
    let after = readFile(extendedPath(path))
    check after == original

  test "a package name starting with a digit is written quoted":
    # reprobuild-pm issue 2026-10-13-package-macro-cannot-declare-a-name-
    # starting-with-a-digit: the 7-Zip package is named `7zip`, which is
    # not a Nim identifier. A profile names it `"7zip"` or
    # `package("7zip"[, "<version>"])`, and the editor writes those forms.
    let dir = createTempDir("repro-home-smoke-digit-", "")
    defer: removeDir(dir)
    let path = dir / "repro-home-smoke-digit.nim"
    writeFile(extendedPath(path), """
import repro/profile

profile "x":
  activity default:
    "7zip"
    package("2fa")
    package("3dtool", "1.2.3")
    package("windows-terminal")
""")
    let act = findActivity(loadProfile(path), "default")
    check act.isSome
    var names: seq[string] = @[]
    var versions: seq[string] = @[]
    for child in act.get.activityChildren:
      names.add child.packageName
      versions.add child.packageVersion
    check names == @["7zip", "2fa", "3dtool", "windows-terminal"]
    check versions == @["", "", "1.2.3", ""]

    let sample = writeSample(dir)
    let original = readFile(extendedPath(sample))
    addPackageReference(sample, "7zip", activity = "default")
    addPackageReference(sample, "9pkg", activity = "default",
      version = "26.01")
    let added = readFile(extendedPath(sample))
    check "\n    \"7zip\"\n" in added
    check "\n    package(\"9pkg\", \"26.01\")\n" in added
    var reread: seq[string] = @[]
    for child in findActivity(loadProfile(sample), "default").get.activityChildren:
      if child.kind == nkPackageRef:
        reread.add child.packageName
    check "7zip" in reread
    check "9pkg" in reread
    removePackageReference(sample, "9pkg", activity = "default",
      version = "26.01")
    removePackageReference(sample, "7zip", activity = "default")
    check readFile(extendedPath(sample)) == original

  test "a package name that is a Nim keyword is written quoted":
    # reprobuild-pm issue 2026-10-15-package-macro-cannot-declare-a-name-
    # that-is-a-nim-keyword: the Nix language server is named `nil`. A
    # profile names it `"nil"`, `` `nil` `` or `package("nil"[, "<ver>"])`,
    # and the editor writes the quoted forms. The quoted forms also reach a
    # control-flow keyword, which only the bare form refuses.
    let dir = createTempDir("repro-home-smoke-keyword-", "")
    defer: removeDir(dir)
    let path = dir / "repro-home-smoke-keyword.nim"
    writeFile(extendedPath(path), """
import repro/profile

profile "x":
  activity default:
    "nil"
    `out`
    package("type")
    package("method", "1.2.3")
    "for"
    `while`
    nil-ls
""")
    let act = findActivity(loadProfile(path), "default")
    check act.isSome
    var names: seq[string] = @[]
    var versions: seq[string] = @[]
    for child in act.get.activityChildren:
      names.add child.packageName
      versions.add child.packageVersion
    check names == @["nil", "out", "type", "method", "for", "while", "nil-ls"]
    check versions == @["", "", "", "1.2.3", "", "", ""]

    let sample = writeSample(dir)
    let original = readFile(extendedPath(sample))
    addPackageReference(sample, "nil", activity = "default")
    addPackageReference(sample, "type", activity = "default",
      version = "26.01")
    let added = readFile(extendedPath(sample))
    check "\n    \"nil\"\n" in added
    check "\n    nil\n" notin added
    check "\n    package(\"type\", \"26.01\")\n" in added
    var reread: seq[string] = @[]
    for child in findActivity(loadProfile(sample), "default").get.activityChildren:
      if child.kind == nkPackageRef:
        reread.add child.packageName
    check "nil" in reread
    check "type" in reread
    removePackageReference(sample, "type", activity = "default",
      version = "26.01")
    removePackageReference(sample, "nil", activity = "default")
    check readFile(extendedPath(sample)) == original

  test "a bare Nim keyword is refused, not read as a package":
    # In the profile macro a bare `nil` line is the `nil` literal, not the
    # package `nil`; the text parser must not report a package the compiled
    # profile does not have. Keywords match style-insensitively (`n_il`).
    let dir = createTempDir("repro-home-smoke-barekw-", "")
    defer: removeDir(dir)
    for body in ["nil", "n_il", "out", "package(nil)", "package(type)",
                 "package(nil, \"1.0\")"]:
      let path = dir / "bad.nim"
      writeFile(extendedPath(path), "import repro/profile\n\n" &
        "profile \"x\":\n  activity default:\n    " & body & "\n")
      checkpoint body
      expect EUnstructured:
        discard loadProfile(path)
    # The refusal names the quoted form that does reach the name.
    let path = dir / "bad-nil.nim"
    writeFile(extendedPath(path), "import repro/profile\n\n" &
      "profile \"x\":\n  activity default:\n    nil\n")
    try:
      discard loadProfile(path)
      check false
    except EUnstructured as e:
      checkpoint e.msg
      check "keyword `nil`" in e.msg
      check "\"nil\"" in e.msg

  test "a quoted package name must be non-empty and closed":
    let dir = createTempDir("repro-home-smoke-badquote-", "")
    defer: removeDir(dir)
    for body in ["\"\"", "\"7zip", "package(\"\")", "package(\"7 zip\")"]:
      let path = dir / "bad.nim"
      writeFile(extendedPath(path), "import repro/profile\n\n" &
        "profile \"x\":\n  activity default:\n    " & body & "\n")
      checkpoint body
      expect EUnstructured:
        discard loadProfile(path)

  test "setConfigurable creates config + sub-block + entry":
    # Use a profile WITHOUT a config block.
    let p = """
import repro/profile

profile "x":
  activity default:
    neovim
"""
    let dir = createTempDir("repro-home-smoke-set-config-", "")
    defer: removeDir(dir)
    let path = dir / "repro-home-smoke-set-config.nim"
    writeFile(extendedPath(path), p)
    setConfigurable(path, "git.userName", "Zahary", nil)
    setConfigurable(path, "git.userEmail", "z@example.com", nil)
    let after = readFile(extendedPath(path))
    check "config:" in after
    check "git:" in after
    check "userName = \"Zahary\"" in after
    check "userEmail = \"z@example.com\"" in after
    # The git: header must appear before either entry.
    let gitHeader = after.find("git:")
    let nameLine = after.find("userName")
    let emailLine = after.find("userEmail")
    check gitHeader >= 0
    check gitHeader < nameLine
    check nameLine < emailLine

  # ---------------------------------------------------------------------
  # M82 home-scope follow-up: `depends_on` shape validation.
  #
  # The parser must reject malformed `depends_on = [...]` entries on the
  # resource attribute with `EUnstructured` naming the offending text.
  # The parser does NOT validate the KIND TAG against a closed set —
  # only the SHAPE (list literal of `"kind:name"` strings with non-empty
  # halves around the first `:`). The planner catches a typo'd kind
  # downstream when no resource satisfies the `(kind, name)` pair.
  # ---------------------------------------------------------------------

  test "depends_on shape validation: rejects non-list RHS":
    var caught = false
    try:
      discard parseDependsOnAttr("/tmp/x.nim",
        IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
        IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
          resourceAttrValueSource: "\"fs.managedBlock:other\"",
          resourceAttrLine: 7))
    except EUnstructured as e:
      caught = true
      check "list literal" in e.expected
      check e.line == 7
    check caught

  test "depends_on shape validation: rejects empty entry":
    var caught = false
    try:
      discard parseDependsOnAttr("/tmp/x.nim",
        IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
        IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
          resourceAttrValueSource: "[\"fs.managedBlock:a\", \"\"]",
          resourceAttrLine: 11))
    except EUnstructured as e:
      caught = true
      check "non-empty 'kind:name'" in e.expected
      check e.line == 11
    check caught

  test "depends_on shape validation: rejects no-colon entry":
    var caught = false
    try:
      discard parseDependsOnAttr("/tmp/x.nim",
        IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
        IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
          resourceAttrValueSource: "[\"no-colon-here\"]",
          resourceAttrLine: 4))
    except EUnstructured as e:
      caught = true
      check "':' separator" in e.expected
    check caught

  test "depends_on shape validation: rejects empty kind half":
    var caught = false
    try:
      discard parseDependsOnAttr("/tmp/x.nim",
        IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
        IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
          resourceAttrValueSource: "[\":someName\"]",
          resourceAttrLine: 3))
    except EUnstructured as e:
      caught = true
      check "non-empty kind" in e.expected
    check caught

  test "depends_on shape validation: rejects empty name half":
    var caught = false
    try:
      discard parseDependsOnAttr("/tmp/x.nim",
        IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
        IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
          resourceAttrValueSource: "[\"fs.managedBlock:\"]",
          resourceAttrLine: 2))
    except EUnstructured as e:
      caught = true
      check "non-empty name" in e.expected
    check caught

  test "depends_on shape validation: accepts a well-formed list":
    # A well-formed list with two entries; first-colon-split keeps the
    # full name half even when it contains further colons (e.g. a
    # resource address with a `:` in it, or a registry key path).
    let parsed = parseDependsOnAttr("/tmp/x.nim",
      IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
      IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
        resourceAttrValueSource:
          "[\"fs.managedBlock:bashrc\", \"env.userVariable:editor:nvim\"]",
        resourceAttrLine: 9))
    check parsed.len == 2
    check parsed[0].kind == "fs.managedBlock"
    check parsed[0].name == "bashrc"
    check parsed[1].kind == "env.userVariable"
    check parsed[1].name == "editor:nvim"   # first-colon-split

  test "effective config buckets enabled vs inert overrides":
    let dir = createTempDir("repro-home-smoke-effective-config-", "")
    defer: removeDir(dir)
    let path = writeSample(dir)
    let prof = loadProfile(path)
    let ctxLaptop = HostContext(platform: "linux", arch: "x86_64",
      host: "dev-laptop")
    let cfg = resolveEffectiveConfig(prof, "dev-laptop", ctxLaptop)
    check "neovim" in cfg.enabledPackages
    check "tmux" in cfg.enabledPackages
    check "git" in cfg.enabledPackages          # via develop_software
    check "windows-terminal" notin cfg.enabledPackages  # gated by `windows`
    check "git" in cfg.overrides
    check "userName" in cfg.overrides["git"]
    check cfg.inertOverrides.len == 0

  # ---------------------------------------------------------------------
  # fs.userFile resource kind acceptance — the parser must accept the
  # new home-scope kind in `KnownResourceKinds` and refuse a typo'd
  # variant (`fs.userFiles`). The parser does NOT validate the per-kind
  # attribute closed-set today; that lives in `resourceFromEntry` in
  # the apply pipeline (where the dispatch knows which kind requires
  # which attributes). The parser exists to ensure the SHAPE compiles.
  # ---------------------------------------------------------------------

  test "fs.userFile: parser accepts a minimal stanza":
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    fs.userFile gpgConf:
      hostFile = "~/.gnupg/gpg.conf"
      content = "default-key F8A8\nkeyserver hkps://keys.openpgp.org\n"
      mode = "0600"
"""
    let dir = createTempDir("repro-home-userfile-accept-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    let prof = loadProfile(path)
    # No exception — the parser recognized the kind. The body of the
    # stanza is preserved as raw nkResourceAttr lines; no per-kind
    # validation here.
    check prof.root.kind == nkProfileRoot

  test "fs.userFile: parser rejects a typo'd kind":
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    fs.userFiles bad:
      hostFile = "~/x"
      content = "y"
"""
    let dir = createTempDir("repro-home-userfile-typo-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    expect EUnstructured:
      discard loadProfile(path)

  test "fs.userFile: parser accepts the executable shorthand attribute":
    # `executable = true` is just one more attribute key — the parser
    # accepts ANY `<key> = <value>` line, with the per-kind closed-set
    # enforced downstream in `resourceFromEntry`.
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    fs.userFile codexWrapper:
      hostFile = "~/.local/bin/codex-no-sandbox"
      content = "#!/usr/bin/env bash\nexec codex --no-sandbox \"$@\"\n"
      mode = "0755"
      executable = true
"""
    let dir = createTempDir("repro-home-userfile-exec-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    let prof = loadProfile(path)
    check prof.root.kind == nkProfileRoot

  # ---------------------------------------------------------------------
  # M83 step 4b: parser acceptance for the two new POSIX home-scope
  # user-services kinds. The text-level parser only checks the kind tag
  # belongs to `KnownResourceKinds` — per-kind attribute closed-sets are
  # enforced in `repro_home_apply/pipeline.nim::resourceFromEntry`.
  # ---------------------------------------------------------------------

  test "systemd.userUnit: parser accepts a minimal stanza":
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    systemd.userUnit gpgAgent:
      name = "gpg-agent.service"
      content = "[Unit]\nDescription=gpg-agent\n[Service]\nExecStart=/usr/bin/gpg-agent --daemon\n"
      enabled = true
      state = "Running"
"""
    let dir = createTempDir("repro-home-systemd-accept-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    let prof = loadProfile(path)
    check prof.root.kind == nkProfileRoot

  test "launchd.userAgent: parser accepts a minimal stanza":
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    launchd.userAgent hammerspoon:
      label = "org.hammerspoon.Hammerspoon"
      programArgs = "/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon"
      runAtLoad = true
      keepAlive = true
"""
    let dir = createTempDir("repro-home-launchd-accept-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    let prof = loadProfile(path)
    check prof.root.kind == nkProfileRoot

  test "systemd.userUnit: parser rejects a typo'd kind":
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    systemd.userUnits bad:
      name = "x.service"
      content = ""
"""
    let dir = createTempDir("repro-home-systemd-typo-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    expect EUnstructured:
      discard loadProfile(path)

  # ---------------------------------------------------------------------
  # M83 step 7 Driver A: linux.dconfKey resource-kind acceptance —
  # parser accepts the minimal stanza and rejects a typo'd variant.
  # The Linux-only apply path is exercised separately (smoke tests in
  # repro_home_resources); the parser is host-agnostic.
  # ---------------------------------------------------------------------

  test "linux.dconfKey: parser accepts a minimal stanza":
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    linux.dconfKey colorScheme:
      key = "/org/gnome/desktop/interface/color-scheme"
      value = "'prefer-dark'"
"""
    let dir = createTempDir("repro-home-dconf-accept-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    let prof = loadProfile(path)
    check prof.root.kind == nkProfileRoot

  test "linux.dconfKey: parser rejects a typo'd kind":
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    linux.dconfKeys bad:
      key = "/org/gnome/x"
      value = "'x'"
"""
    let dir = createTempDir("repro-home-dconf-typo-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    expect EUnstructured:
      discard loadProfile(path)

  # ---------------------------------------------------------------------
  # M83 step 7 Driver B: linux.kdeConfigKey resource-kind acceptance.
  # ---------------------------------------------------------------------

  test "linux.kdeConfigKey: parser accepts a minimal stanza":
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    linux.kdeConfigKey colorScheme:
      file = "kdeglobals"
      group = "General"
      key = "ColorScheme"
      value = "BreezeDark"
"""
    let dir = createTempDir("repro-home-kde-accept-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    let prof = loadProfile(path)
    check prof.root.kind == nkProfileRoot

  test "linux.kdeConfigKey: parser accepts an explicit kdeVersion":
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    linux.kdeConfigKey colorSchemeV5:
      file = "kdeglobals"
      group = "General"
      key = "ColorScheme"
      value = "BreezeDark"
      kdeVersion = 5
"""
    let dir = createTempDir("repro-home-kde-v5-accept-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    let prof = loadProfile(path)
    check prof.root.kind == nkProfileRoot

  test "linux.kdeConfigKey: parser rejects a typo'd kind":
    let src = """
import repro/profile

profile "x":
  activity default:
    neovim

  resources:
    linux.kdeConfigKeys bad:
      file = "kdeglobals"
      group = "General"
      key = "K"
      value = "v"
"""
    let dir = createTempDir("repro-home-kde-typo-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), src)
    expect EUnstructured:
      discard loadProfile(path)

suite "GM4: plan-time data files (intent layer)":

  test "the text inspector reads the data: section and refuses bad paths":
    let dir = createTempDir("repro-home-gm4-data-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), """
import repro/profile

profile "gm4":
  data:
    "data/apps.toml"   # applications
    "cli.toml"

  activity default:
    neovim
""")
    let prof = loadProfile(path)
    check prof.dataFileRefs == @["data/apps.toml", "cli.toml"]
    check findActivity(prof, "default").isSome
    # An edit elsewhere leaves the data section byte-identical.
    let before = readFile(path)
    addPackageReference(path, "tmux")
    check readFile(path).contains("    \"data/apps.toml\"   # applications\n")
    check readFile(path).len > before.len
    for bad in ["\"../apps.toml\"", "\"/etc/apps.toml\"", "\"a\\\\b.toml\"",
                "data/apps.toml", "\"a//b.toml\""]:
      writeFile(extendedPath(path), "import repro/profile\n\n" &
        "profile \"gm4\":\n  data:\n    " & bad & "\n")
      checkpoint(bad)
      expect EUnstructured:
        discard loadProfile(path)

  test "validateBuiltinPredicate accepts the built-in grammar only":
    for good in ["macos", "linux and arm64", "not windows",
                 "host == \"m1\"", "host in [\"a\", \"b\"]",
                 "(linux or bsd) and not wsl", "true", "host != \"x\""]:
      checkpoint(good)
      discard validateBuiltinPredicate(good)
    for unknown in ["headless", "linux and onBattery"]:
      checkpoint(unknown)
      expect EUnknownPredicate:
        discard validateBuiltinPredicate(unknown)
    for mistyped in ["host", "\"m1\"", "linux == \"x\"", "host in \"x\"",
                     "macos and", "[\"a\"]"]:
      checkpoint(mistyped)
      expect EUnstructured:
        discard validateBuiltinPredicate(mistyped)

  test "appendPackageRow keeps every existing byte and reads back":
    let dir = createTempDir("repro-home-gm4-append-", "")
    defer: removeDir(dir)
    let profilePath = dir / "home.nim"
    let original = "# header comment\n[[package]]\nname = \"jq\"\n" &
      "activity = \"default\"   # trailing\n"
    createDir(dir / "data")
    writeFile(extendedPath(dir / "data" / "apps.toml"), original)
    let row = DataPackageRow(name: "ghostty", activity: "desktop",
      whenPredicate: "macos", binaries: @["ghostty"])
    check appendPackageRow(profilePath, dir, "data/apps.toml", row) ==
      aroAppended
    let updated = readFile(dir / "data" / "apps.toml")
    check updated.startsWith(original)
    check updated == original & "\n" & renderPackageRow(row)
    let rows = parseDataFileText(profilePath, "data/apps.toml", updated)
    check rows.len == 2
    check sameRow(rows[1], row)
    # The same row (guard spelled differently) is already present.
    var respelled = row
    respelled.whenPredicate = " macos "
    check appendPackageRow(profilePath, dir, "data/apps.toml", respelled) ==
      aroAlreadyPresent
    check readFile(dir / "data" / "apps.toml") == updated
    # A row the planner would refuse is never written.
    var bad = row
    bad.whenPredicate = "macos and headless"
    expect EDataFile:
      discard appendPackageRow(profilePath, dir, "data/apps.toml", bad)
    check readFile(dir / "data" / "apps.toml") == updated
    # A missing (declared) file is created.
    check appendPackageRow(profilePath, dir, "data/new.toml", row) ==
      aroCreated
    check readFile(dir / "data" / "new.toml") == renderPackageRow(row)

  test "resource rows are built by the profile's resource constructors":
    let text = """
[[package]]
name = "jq"
activity = "default"

[[resource]]
kind = "fs.userFile"
when = "linux and x86_64"
hostFile = "~/.config/gm4/a.conf"
content = "a = 1\n"

[[resource]]
kind = "launchd.userAgent"
label = "org.gm4.agent"
programArgs = ["/usr/bin/true"]
keepAlive = true
"""
    let rows = parseDataFileRows("home.nim", "data/apps.toml", text)
    check rows.packages.len == 1
    check rows.resources.len == 2
    let file = rows.resources[0]
    # Exactly what `fsUserFile(hostFile = ..., content = ...)` declares:
    # the constructor's defaults and auto-address.
    var direct: seq[ResourceIntent]
    fsUserFile(direct, hostFile = "~/.config/gm4/a.conf", content = "a = 1\n")
    var guarded = direct[0]
    guarded.guard = PredicateExpr(expr: canonicalize("linux and x86_64"))
    check emitProfileIntentJson(ProfileIntent(resources: @[file])) ==
      emitProfileIntentJson(ProfileIntent(resources: @[guarded]))
    check file.fields["mode"].s == "0644"
    check file.guard.expr == canonicalize("linux and x86_64")
    let agent = rows.resources[1]
    check agent.kind == "launchd.userAgent"
    check agent.fields["keepAlive"].b
    check agent.fields["runAtLoad"].b            # the constructor's default
    check agent.guard.expr == ""
    # Every supported kind builds its own kind from its required keys.
    for k in ResourceRowKinds:
      var fields: ResourceRowFields
      for key in k.required:
        let probe = (if key in ["programArgs", "extensions"]:
                       listField(@["x"]) else: strField("x"))
        fields[key] = probe
      checkpoint(k.kind)
      check constructResourceRow(k.kind, fields).kind == k.kind

  test "resource rows outside a constructor's signature are refused":
    proc refusal(row: string): string =
      try:
        discard parseDataFileRows("home.nim", "data/r.toml",
          "[[resource]]\n" & row)
      except EDataFile as e:
        return e.msg
      ""
    check refusal("kind = \"fs.systemFile\"\npath = \"/etc/x\"\n").contains(
      "not a resource kind a data row can declare")
    check refusal("hostFile = \"~/x\"\n").contains("`kind`")
    check refusal("kind = \"fs.userFile\"\ncontent = \"x\"\n").contains(
      "`hostFile`")
    check refusal("kind = \"fs.userFile\"\nhostFile = \"~/x\"\n" &
      "owner = \"me\"\n").contains("unknown key")
    check refusal("kind = \"fs.userFile\"\nhostFile = \"~/x\"\n" &
      "executable = \"yes\"\n").contains("expected a boolean")
    check refusal("kind = \"fs.userFile\"\nhostFile = \"~/x\"\n" &
      "when = \"headless\"\n").contains("not a built-in predicate")
    check refusal("kind = \"windows.registryValueHKCU\"\n").contains(
      "not a resource kind")

  test "removePackageRows removes only the matching rows' lines":
    let dir = createTempDir("repro-home-gm4-remove-", "")
    defer: removeDir(dir)
    let profilePath = dir / "home.nim"
    createDir(dir / "data")
    let path = dir / "data" / "apps.toml"
    let head = "# Applications.\n\n"
    let a = "[[package]]\nname = \"jq\"\nactivity = \"default\"\n"
    let b = "[[package]]\nname = \"fd\"   # finder\nactivity = \"cli\"\n" &
      "when = \"linux\"\n"
    let c = "# the macOS terminal\n[[package]]\nname = \"fd\"\n" &
      "activity = \"desktop\"\n"
    let r = "[[resource]]\nkind = \"fs.userFile\"\nhostFile = \"~/x\"\n"
    let original = head & a & "\n" & b & "\n" & c & "\n" & r
    writeFile(extendedPath(path), original)
    # Narrowed by activity and guard: only `b` goes.
    check removePackageRows(profilePath, dir, "data/apps.toml", "fd",
      activity = "cli", predicate = " linux ") == 1
    check readFile(path) == head & a & "\n" & c & "\n" & r
    # No match: unchanged.
    check removePackageRows(profilePath, dir, "data/apps.toml", "fd",
      activity = "cli") == 0
    check readFile(path) == head & a & "\n" & c & "\n" & r
    # By name: `c` goes; its leading comment is not part of the row.
    check removePackageRows(profilePath, dir, "data/apps.toml", "fd") == 1
    check readFile(path) == head & a & "\n# the macOS terminal\n" & r
    # Inline tables cannot be edited structurally.
    writeFile(extendedPath(path),
      "package = [{ name = \"jq\", activity = \"default\" }]\n")
    expect EDataFile:
      discard removePackageRows(profilePath, dir, "data/apps.toml", "jq")
