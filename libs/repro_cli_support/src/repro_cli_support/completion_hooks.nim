## `repro hooks ensure|reinstall|uninstall --shell-autocomplete`: shell
## completion for `repro`, installed for every shell found.
##
## What is written, and where, is clispec's table
## (`clispec/completion_install`): the script `repro completion <shell>`
## prints, saved where the shell loads completion on its own, plus a managed
## block in an rc or profile file only where the shell needs one to load it
## (Zsh's `fpath`, PowerShell's profile, and Bash when bash-completion is not
## installed). This module decides which of those targets apply and writes
## them, under these rules:
##
## * **Idempotent.** A file already holding the current script, or a block
##   already holding the current text, is left alone and reported
##   `unchanged`; a second run writes nothing.
## * **Never replaces another tool's file.** A file at a target path that is
##   not a clispec-generated `repro` script is left byte-for-byte as it is and
##   reported `refused-foreign`, as is a target behind a Nix-store or
##   read-only symlink (`shell_rc_files.rcFileWritePath`). The command visits
##   every other shell first and then exits 1.
## * **Registered once.** Per user, a shell whose system-wide location (the
##   local administrator's, or a native package's for this platform) already
##   holds the `repro` script is reported `already-registered-system` and
##   nothing is written for it, so the user does not end up with a second
##   copy to keep in step, or, through an rc block, a second registration.
## * **Uninstall** removes only files that carry clispec's generated header
##   for `repro`, and the managed blocks. A foreign file is left in place and
##   reported `kept-foreign`.
## * **The test root.** `systemRoot` (the internal `--system-root`) prefixes
##   every system path written or consulted: the `--system` targets,
##   `/etc/shells`, the system locations of "registered once", where
##   bash-completion is looked for, and PowerShell's `$PSHOME`. Tests run
##   `--system` through it without touching the machine. A `--system` target
##   that resolves outside the root (through a symlink inside it) is
##   reported `failed` and not touched (`requireUnderRoot`).
##
## The blocks go through the one managed-block writer
## (`repro_home_resources/drivers/managed_block`), with ids
## `repro-completion-<shell>`, distinct from the native shell hook's
## `repro-dev-env-native-<shell>`, so the two never overwrite each other.
## Every write is checked against the test-home fence first.

import std/[json, os, strutils]

import clispec/[completion, completion_install]
from repro_core/paths import extendedPath
import repro_core/durable_replace
import repro_home_resources/drivers/managed_block
import repro_home_resources/test_home_fence

import ./shell_detect
import ./shell_rc_files

export completion_install

when not defined(windows):
  from std/posix import access, W_OK

when defined(windows):
  import std/widestrs

  proc shGetFolderPathW(hwnd: pointer; csidl: cint; token: pointer;
                        flags: uint32; path: ptr Utf16Char): int32
    {.stdcall, dynlib: "shell32.dll", importc: "SHGetFolderPathW".}

  proc windowsDocumentsDir*(): string =
    ## The user's Documents folder as Windows reports it
    ## (``CSIDL_PERSONAL``, what ``[Environment]::GetFolderPath('MyDocuments')``
    ## returns), which folder redirection (OneDrive) can move away from
    ## ``%USERPROFILE%\Documents``
    ## (https://learn.microsoft.com/windows/win32/api/shlobj_core/nf-shlobj_core-shgetfolderpathw).
    ## "" when it cannot be read.
    const csidlPersonal = 5'i32
    var buf: array[261, Utf16Char]
    if shGetFolderPathW(nil, csidlPersonal, nil, 0, addr buf[0]) == 0:
      result = $cast[WideCString](addr buf[0])
else:
  proc windowsDocumentsDir*(): string =
    ## Windows only; "" elsewhere, where PowerShell's profile does not live
    ## under Documents.
    ""

const
  CompletionBlockPrefix* = "repro-completion-"
    ## The managed-block id prefix of a completion block; the shell's name
    ## follows.

type
  CompletionScope* = enum
    ## `--profile` (the default) or `--system`.
    csUser = "user"
    csSystem = "system"

  CompletionOutcome* = enum
    ## What happened to one target. The refusals and `failed` make the
    ## command exit 1.
    coInstalled = "installed"
    coUnchanged = "unchanged"
    coAlreadyRegisteredSystem = "already-registered-system"
    coRefusedForeign = "refused-foreign"
    coRefusedUnwritable = "refused-unwritable"
    coFailed = "failed"
    coRemoved = "removed"
    coKeptForeign = "kept-foreign"
    coAbsent = "absent"

  CompletionHookEntry* = object
    ## One line of the report: `kind: "completion"` in `hooks-report.json`.
    shell*: CliShell
    scope*: CompletionScope
    target*: CliTargetKind
    path*: string
    outcome*: CompletionOutcome
    detail*: string    ## why, for a refusal or a failure

  CompletionHookRequest* = object
    ## Everything an install or removal depends on. The caller fills it from
    ## the process (`HOME`, `PATH`, ...); tests fill it however they like.
    scope*: CompletionScope
    systemRoot*: string   ## prefixes every system path; "" for none
    reinstall*: bool      ## rewrite even what is already current
    program*: string      ## the command completion is registered for
    env*: CliInstallEnv
    pathEnv*: string      ## the `PATH` shells are detected on
    user*: string         ## the user name, for `/etc/profiles/per-user`
    windows*: bool
    script*: proc (shell: CliShell): string {.closure.}
      ## The script `<program> completion <shell>` prints.

proc completionBlockId*(shell: CliShell): string =
  CompletionBlockPrefix & $shell

proc cliShellOf(kind: NativeShellKind): CliShell =
  case kind
  of nskBash: cshBash
  of nskZsh: cshZsh
  of nskFish: cshFish
  of nskPowerShell: cshPowerShell

proc rooted*(root, path: string): string =
  ## `path` under `root` ("" leaves it as it is).
  if root.len == 0:
    return path
  var rest = path
  if rest.len >= 2 and rest[1] == ':':
    rest = rest[2 .. ^1]
  root / rest.strip(trailing = false, chars = {'/', '\\'})

type RootEscapeError* = object of CatchableError
  ## A `--system-root` target that resolves outside the root.

proc requireUnderRoot*(req: CompletionHookRequest; path: string) =
  ## Under `--system --system-root=ROOT`, refuse to touch `path` unless it
  ## resolves inside ROOT: the nearest existing ancestor of `path` (the file
  ## itself when it exists), with symlinks resolved, must be ROOT or below
  ## it. `rooted` alone only prefixes the path, so a symlink inside the root
  ## (`ROOT/usr/local -> /usr/local`) would otherwise carry the write onto
  ## the machine the root is there to protect. Raises `RootEscapeError`,
  ## which the callers report as `failed`.
  if req.scope != csSystem or req.systemRoot.len == 0:
    return
  proc real(p: string): string =
    try: expandFilename(p) except OSError: absolutePath(p)
  let root = real(req.systemRoot)
  var probe = absolutePath(path)
  while not (fileExists(probe) or dirExists(probe)):
    let parent = parentDir(probe)
    if parent.len == 0 or parent == probe:
      break
    probe = parent
  let resolved = real(probe)
  if resolved != root and not resolved.startsWith(root / ""):
    raise newException(RootEscapeError, path & " resolves to " & resolved &
      ", outside --system-root " & req.systemRoot & "; nothing written")

proc isFailure*(outcome: CompletionOutcome): bool =
  outcome in {coRefusedForeign, coRefusedUnwritable, coFailed}

proc completionExitCode*(entries: openArray[CompletionHookEntry]): int =
  ## 1 when any target was refused or failed, else 0.
  for e in entries:
    if e.outcome.isFailure:
      return 1
  0

proc toJsonNode*(e: CompletionHookEntry): JsonNode =
  result = %*{"kind": "completion", "shell": $e.shell, "scope": $e.scope,
    "target": $e.target, "path": e.path, "outcome": $e.outcome}
  if e.detail.len > 0:
    result["detail"] = %e.detail

proc describe(e: CompletionHookEntry): string =
  $e.shell & " completion" &
    (if e.target == ctkProfileBlock: " block" else: "")

proc reportLine*(e: CompletionHookEntry): tuple[text: string; toStderr: bool] =
  ## The line `repro hooks` prints for `e`, and whether it goes to stderr.
  let what = describe(e)
  case e.outcome
  of coInstalled: ("repro hooks: ensured " & what & " at " & e.path, false)
  of coUnchanged:
    ("repro hooks: " & what & " at " & e.path & " is unchanged", false)
  of coAlreadyRegisteredSystem:
    ("repro hooks: " & $e.shell & " completion is already registered " &
      "system-wide at " & e.path & "; nothing written for this user", false)
  of coRemoved: ("repro hooks: removed " & what & " from " & e.path, false)
  of coAbsent: ("repro hooks: no " & what & " at " & e.path, false)
  of coKeptForeign:
    ("repro hooks: left " & e.path & " in place: " & e.detail, false)
  of coRefusedForeign, coRefusedUnwritable:
    ("repro hooks: REFUSED " & what & " at " & e.path & ": " & e.detail, true)
  of coFailed:
    ("repro hooks: could NOT write " & what & " at " & e.path & ": " &
      e.detail, true)

proc printEntries*(entries: openArray[CompletionHookEntry]) =
  for e in entries:
    let (text, toStderr) = reportLine(e)
    if toStderr: stderr.writeLine(text) else: stdout.writeLine(text)

# ---------------------------------------------------------------------------
# Where things are.
# ---------------------------------------------------------------------------

proc hostFamilies(): seq[(CliPlatformFamily, string)] =
  ## Where this platform's native packages put completion files, as
  ## (family, prefix): what "registered once" consults besides the
  ## `--system` location.
  when defined(macosx):
    @[(cpfMacosPkg, ""), (cpfHomebrew, "/opt/homebrew"),
      (cpfHomebrew, "/usr/local")]
  elif defined(freebsd):
    @[(cpfFreeBsd, "")]
  elif defined(openbsd) or defined(netbsd):
    @[(cpfOpenBsd, ""), (cpfOpenBsd, "/usr/pkg")]
  else:
    @[(cpfDebian, ""), (cpfRpm, "")]

# The `--system` family: the local administrator's area. On Linux, Fish's
# script goes in fish's configuration directory (`/etc/fish/completions`)
# instead of `/usr/local/share`, which fish searches only when
# `XDG_DATA_DIRS` names it (clispec `cpfLinuxLocal`).
const localFamily = (when defined(linux): cpfLinuxLocal else: cpfLocal)

proc localSystemTargets(req: CompletionHookRequest; shell: CliShell;
                        psHome = ""): seq[CliCompletionTarget] =
  ## The `--system` targets of `shell`, every path under the test root: the
  ## prefix and the configuration directory alike.
  cliSystemCompletionTargets(shell, req.program, localFamily,
    rooted(req.systemRoot, cliDefaultPrefix(localFamily)), psHome,
    sysconfDir = rooted(req.systemRoot, "/etc"))

proc systemRegistrationPaths(req: CompletionHookRequest;
                             shell: CliShell): seq[string] =
  ## Every system-wide script file of `shell` that counts as an existing
  ## registration, under the test root.
  if req.windows:
    return @[]
  var families = @[(localFamily, "")] & hostFamilies()
  # Nix: the system profiles' `share/` (NixOS, nix-darwin, Home Manager's
  # per-user profile under /etc/profiles).
  for prefix in ["/run/current-system/sw", "/nix/var/nix/profiles/default"]:
    families.add((cpfNix, prefix))
  if req.user.len > 0:
    families.add((cpfNix, "/etc/profiles/per-user/" & req.user))
  for (family, prefix) in families:
    for t in cliSystemCompletionTargets(shell, req.program, family, prefix):
      if t.kind == ctkFile:
        let p = rooted(req.systemRoot, t.path)
        if p notin result:
          result.add(p)

proc bashCompletionInstalled(req: CompletionHookRequest): bool =
  for loader in cliBashCompletionLoaders():
    if fileExists(rooted(req.systemRoot, loader)):
      return true
  false

proc powerShellHome(executable: string): string =
  ## The `$PSHOME` of the PowerShell at `executable`, found without running
  ## it: the directory that holds `System.Management.Automation.dll`, which
  ## is the executable's own (Microsoft's packages; symlinks resolved) or,
  ## for a wrapper script, `../share/powershell` beside it (nixpkgs). "" when
  ## neither holds it.
  const marker = "System.Management.Automation.dll"
  var exe = executable
  try:
    exe = expandFilename(executable)
  except OSError:
    discard
  let dir = parentDir(exe)
  if fileExists(dir / marker):
    return dir
  let shared = parentDir(dir) / "share" / "powershell"
  if fileExists(shared / marker):
    return shared
  ""

proc writableDir(dir: string): bool =
  ## Whether a file can be created in `dir`, or, when it does not exist yet,
  ## in its nearest existing ancestor.
  var d = dir
  while d.len > 0 and not dirExists(d):
    let parent = parentDir(d)
    if parent == d:
      break
    d = parent
  when defined(windows):
    dirExists(d)
  else:
    dirExists(d) and access(d.cstring, W_OK) == 0

# ---------------------------------------------------------------------------
# Writing one target.
# ---------------------------------------------------------------------------

proc ensureFile(req: CompletionHookRequest; shell: CliShell;
                path, content: string): CompletionHookEntry =
  result = CompletionHookEntry(shell: shell, scope: req.scope,
    target: ctkFile, path: path)
  try:
    enforceTestHomeFence(path, "shell completion file")
    let writePath = rcFileWritePath(path, req.systemRoot)
    requireUnderRoot(req, writePath)
    if fileExists(extendedPath(writePath)):
      let existing = readFile(extendedPath(writePath))
      if existing == content and not req.reinstall:
        result.outcome = coUnchanged
        return
      if not cliIsGeneratedCompletionScript(existing, shell, req.program):
        result.outcome = coRefusedForeign
        result.detail = "it is not a " & req.program &
          " completion script generated by clispec; remove or move it " &
          "and run this again"
        return
    createDir(extendedPath(parentDir(writePath)))
    replaceFileDurably(writePath, content)
    when not defined(windows):
      setFilePermissions(extendedPath(writePath), {fpUserRead, fpUserWrite,
        fpGroupRead, fpOthersRead})
    result.outcome = coInstalled
  except ValueError as err:
    # rcFileWritePath: a Nix-store or read-only target another tool owns.
    result.outcome = coRefusedForeign
    result.detail = err.msg
  except CatchableError as err:
    result.outcome = coFailed
    result.detail = err.msg

proc ensureBlock(req: CompletionHookRequest; shell: CliShell;
                 path, body: string): CompletionHookEntry =
  result = CompletionHookEntry(shell: shell, scope: req.scope,
    target: ctkProfileBlock, path: path)
  let blockId = completionBlockId(shell)
  try:
    enforceTestHomeFence(path, "shell completion block")
    let writePath = rcFileWritePath(path, req.systemRoot)
    requireUnderRoot(req, writePath)
    if not req.reinstall and fileExists(extendedPath(writePath)):
      let found = readHomeManagedBlockBody(readFile(extendedPath(writePath)),
        blockId, writePath)
      if found.found and found.body.strip(leading = false, chars = {'\n'}) ==
          body.strip(leading = false, chars = {'\n'}):
        result.outcome = coUnchanged
        return
    if req.reinstall:
      destroyManagedBlockResource(writePath, blockId)
    discard applyManagedBlockResource(writePath, blockId, body)
    result.outcome = coInstalled
  except ValueError as err:
    result.outcome = coRefusedForeign
    result.detail = err.msg
  except CatchableError as err:
    result.outcome = coFailed
    result.detail = err.msg

proc removeFileTarget(req: CompletionHookRequest; shell: CliShell;
                      path: string): CompletionHookEntry =
  result = CompletionHookEntry(shell: shell, scope: req.scope,
    target: ctkFile, path: path)
  try:
    if not fileExists(extendedPath(path)) and
        not symlinkExists(extendedPath(path)):
      result.outcome = coAbsent
      return
    enforceTestHomeFence(path, "shell completion file removal")
    requireUnderRoot(req, path)
    let content =
      if fileExists(extendedPath(path)): readFile(extendedPath(path)) else: ""
    if symlinkExists(extendedPath(path)) or
        not cliIsGeneratedCompletionScript(content, shell, req.program):
      result.outcome = coKeptForeign
      result.detail = "it is not a " & req.program &
        " completion script repro writes"
      return
    removeFile(extendedPath(path))
    result.outcome = coRemoved
  except CatchableError as err:
    result.outcome = coFailed
    result.detail = err.msg

proc removeBlockTarget(req: CompletionHookRequest; shell: CliShell;
                       path: string): CompletionHookEntry =
  result = CompletionHookEntry(shell: shell, scope: req.scope,
    target: ctkProfileBlock, path: path)
  let blockId = completionBlockId(shell)
  try:
    if not fileExists(extendedPath(path)):
      result.outcome = coAbsent
      return
    let writePath = rcFileWritePath(path, req.systemRoot)
    requireUnderRoot(req, writePath)
    let found = readHomeManagedBlockBody(readFile(extendedPath(writePath)),
      blockId, writePath)
    if not found.found:
      result.outcome = coAbsent
      return
    destroyManagedBlockResource(writePath, blockId)
    result.outcome = coRemoved
  except ValueError as err:
    result.outcome = coRefusedForeign
    result.detail = err.msg
  except CatchableError as err:
    result.outcome = coFailed
    result.detail = err.msg

# ---------------------------------------------------------------------------
# The targets of one shell.
# ---------------------------------------------------------------------------

type ShellFound = object
  shell: CliShell
  editions: seq[CliPowerShellEdition]
  executables: seq[string]

proc foundShells(req: CompletionHookRequest): seq[ShellFound] =
  ## The detected shells, one entry per completion shell (both PowerShells
  ## under one).
  let etcShells =
    if req.scope == csSystem: rooted(req.systemRoot, "/etc/shells") else: ""
  for d in detectShells(req.pathEnv, etcShells, req.windows):
    let shell = cliShellOf(d.kind)
    var at = -1
    for i, f in result:
      if f.shell == shell:
        at = i
    if at < 0:
      result.add(ShellFound(shell: shell))
      at = result.high
    if shell == cshPowerShell:
      result[at].editions.add(
        if d.command == "powershell": cpeWindows else: cpePwsh)
    result[at].executables.add(d.executable)

proc wantedTargets(req: CompletionHookRequest; found: ShellFound):
    tuple[targets: seq[CliCompletionTarget]; refusal, refusedAt: string] =
  ## The targets to write for one detected shell, or why none can be.
  case req.scope
  of csUser:
    for t in cliUserCompletionTargets(found.shell, req.program, req.env,
        req.windows):
      if t.kind == ctkProfileBlock:
        if t.onlyWithoutLoader and bashCompletionInstalled(req):
          continue
        if found.shell == cshPowerShell and t.edition notin found.editions:
          continue
      result.targets.add(t)
  of csSystem:
    if found.shell != cshPowerShell:
      for t in localSystemTargets(req, found.shell):
        result.targets.add(t)
      return
    var psHome = ""
    for exe in found.executables:
      psHome = powerShellHome(exe)
      if psHome.len > 0:
        break
    if psHome.len == 0:
      result.refusedAt = found.executables.join(", ")
      result.refusal = "cannot tell this PowerShell's $PSHOME (no " &
        "System.Management.Automation.dll beside " &
        found.executables.join(", ") & ")"
      return
    let home = rooted(req.systemRoot, psHome)
    if not writableDir(home):
      result.refusedAt = cliPowerShellAllUsersProfile(home)
      result.refusal = "$PSHOME (" & psHome & ") is not writable, so its " &
        "all-users profile cannot load the script (an MSIX install, or a " &
        "read-only store); use --profile for each user instead"
      return
    for t in localSystemTargets(req, found.shell, home):
      result.targets.add(t)

# ---------------------------------------------------------------------------
# The commands.
# ---------------------------------------------------------------------------

proc ensureCompletionHooks*(req: CompletionHookRequest):
    seq[CompletionHookEntry] =
  ## Install (or, with `reinstall`, rewrite) completion for every detected
  ## shell. Returns one entry per target; `completionExitCode` of them is
  ## the command's status. Every shell is visited even after a refusal.
  if req.windows and req.scope == csSystem:
    raise newException(ValueError,
      "--system shell completion is not specified on Windows; use --profile")
  for found in foundShells(req):
    if req.scope == csUser:
      var registered = ""
      for p in systemRegistrationPaths(req, found.shell):
        if fileExists(extendedPath(p)):
          try:
            if cliIsGeneratedCompletionScript(readFile(extendedPath(p)),
                found.shell, req.program):
              registered = p
              break
          except IOError, OSError:
            discard
      if registered.len > 0:
        result.add CompletionHookEntry(shell: found.shell, scope: req.scope,
          target: ctkFile, path: registered,
          outcome: coAlreadyRegisteredSystem)
        continue
    let wanted = wantedTargets(req, found)
    if wanted.refusal.len > 0:
      result.add CompletionHookEntry(shell: found.shell, scope: req.scope,
        target: ctkProfileBlock, path: wanted.refusedAt,
        outcome: coRefusedUnwritable,
        detail: wanted.refusal)
      continue
    let script = req.script(found.shell)
    var fileOk = true
    for t in wanted.targets:
      case t.kind
      of ctkFile:
        let e = ensureFile(req, found.shell, t.path, script)
        if e.outcome.isFailure:
          fileOk = false
        result.add e
      of ctkProfileBlock:
        # A block loading a file that was not written would load another
        # tool's script, or nothing.
        if fileOk:
          result.add ensureBlock(req, found.shell, t.path,
            cliProfileBlockBody(found.shell, req.program, t.script))

proc uninstallCompletionHooks*(req: CompletionHookRequest):
    seq[CompletionHookEntry] =
  ## Remove what `ensureCompletionHooks` writes for this scope, for every
  ## shell (detected or not: a shell uninstalled since keeps its files
  ## otherwise). Foreign files are left in place.
  if req.windows and req.scope == csSystem:
    raise newException(ValueError,
      "--system shell completion is not specified on Windows; use --profile")
  for shell in CliShell:
    var targets: seq[CliCompletionTarget] = @[]
    case req.scope
    of csUser:
      targets = cliUserCompletionTargets(shell, req.program, req.env,
        req.windows)
    of csSystem:
      var psHome = ""
      if shell == cshPowerShell:
        for found in foundShells(req):
          if found.shell == cshPowerShell:
            for exe in found.executables:
              psHome = powerShellHome(exe)
              if psHome.len > 0:
                break
      targets = localSystemTargets(req, shell,
        (if psHome.len > 0: rooted(req.systemRoot, psHome) else: ""))
    for t in targets:
      case t.kind
      of ctkFile: result.add removeFileTarget(req, shell, t.path)
      of ctkProfileBlock: result.add removeBlockTarget(req, shell, t.path)
