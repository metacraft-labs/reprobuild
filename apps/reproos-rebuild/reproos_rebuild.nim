## ``reproos-rebuild`` CLI — B2 P3.
##
## Subcommands:
##
##   * ``reproos-rebuild apply [--config PATH] [--state-dir DIR]
##     [--boot-dir DIR] [--runtime-dir DIR] [--yes]``
##     Parses ``/etc/reproos/configuration.nim`` (or the
##     ``--config`` override), plans, applies (with a confirmation
##     prompt unless ``--yes`` is passed), and reports the new
##     generation number.
##
##   * ``reproos-rebuild list [--state-dir DIR]``
##     Lists the recorded generations with their timestamps and
##     marks the currently-confirmed one.
##
##   * ``reproos-rebuild plan [--config PATH] [--state-dir DIR]``
##     Plans without applying — emits the diff against the most
##     recent recorded generation. Useful in CI gates.
##
##   * ``reproos-rebuild confirm [--state-dir DIR]``
##     Promotes the staged-next generation to ``current`` and
##     clears ``staged-next``. The
##     ``reproos-confirm-generation.service`` systemd unit runs
##     this on a successful boot; the integration tests invoke it
##     directly to simulate the boot promotion without a real
##     reboot.
##
##   * ``reproos-rebuild grub [--state-dir DIR]``
##     Renders the ``/boot/grub/grub.cfg`` content for the recorded
##     generation set to stdout. The B2 milestone wires this as a
##     side-effect of ``apply``; the standalone subcommand is exposed
##     for the ``t_b2_grub_menu.sh`` gate.
##
## The CLI is intentionally minimal — B3 will extend it with
## ``switch`` / ``rollback`` / ``gc``. Exit codes:
##
##   * 0: success (or no-op apply).
##   * 1: parse error / structured DSL diagnostic.
##   * 2: usage error.
##   * 3: apply aborted by the operator at the confirmation prompt.
##   * 4: state-directory I/O error.

import std/[os, strutils, times]

import repro_system_apply

const ToolName = "reproos-rebuild"
const Version = "0.1.0"
const Usage = """
Usage: reproos-rebuild <subcommand> [options]

Subcommands:
  apply    Parse the configuration, plan, apply, record a new generation.
  plan     Plan only (no apply); emit the diff against the latest generation.
  list     List recorded generations.
  confirm  Promote the staged-next generation to current (post-boot hook).
  grub     Emit the grub.cfg content for the recorded generations.
  help     Show this help text.
  version  Show the version string.

Options (apply / plan):
  --config PATH         Path to configuration.nim. Default:
                        /etc/reproos/configuration.nim
  --state-dir DIR       Override state directory. Default:
                        /var/lib/reproos (Linux), %LOCALAPPDATA%\\reproos (Windows)
  --boot-dir DIR        Override the boot directory. Default: /boot
  --runtime-dir DIR     Override the runtime directory. Default: /run/reproos
  --yes                 Skip the confirmation prompt.
  --activation-ts SECS  Override the activation timestamp (seconds since epoch).
                        Tests use this to produce deterministic manifest bytes.
  --skip-realize        Do not write per-package placeholder files.
                        Tests use this to keep the on-disk tree small.
"""

type
  ParsedArgs = object
    sub: string
    configPath: string
    stateDir: string
    bootDir: string
    runtimeDir: string
    autoYes: bool
    activationTs: int64
    skipRealize: bool

proc parseArgs(): ParsedArgs =
  let args = commandLineParams()
  if args.len == 0:
    result.sub = ""
    return
  result.sub = args[0]
  result.activationTs = 0
  var i = 1
  while i < args.len:
    let a = args[i]
    case a
    of "--config":
      inc i
      if i >= args.len:
        stderr.writeLine "reproos-rebuild: --config requires a path"
        quit(2)
      result.configPath = args[i]
    of "--state-dir":
      inc i
      if i >= args.len:
        stderr.writeLine "reproos-rebuild: --state-dir requires a path"
        quit(2)
      result.stateDir = args[i]
    of "--boot-dir":
      inc i
      if i >= args.len:
        stderr.writeLine "reproos-rebuild: --boot-dir requires a path"
        quit(2)
      result.bootDir = args[i]
    of "--runtime-dir":
      inc i
      if i >= args.len:
        stderr.writeLine "reproos-rebuild: --runtime-dir requires a path"
        quit(2)
      result.runtimeDir = args[i]
    of "--yes", "-y":
      result.autoYes = true
    of "--skip-realize":
      result.skipRealize = true
    of "--activation-ts":
      inc i
      if i >= args.len:
        stderr.writeLine "reproos-rebuild: --activation-ts requires an integer"
        quit(2)
      try:
        result.activationTs = parseBiggestInt(args[i])
      except ValueError:
        stderr.writeLine "reproos-rebuild: --activation-ts must be an integer"
        quit(2)
    else:
      stderr.writeLine "reproos-rebuild: unknown option '" & a & "'"
      quit(2)
    inc i

proc defaultConfigPath(): string =
  when defined(windows):
    let lad = getEnv("LOCALAPPDATA")
    if lad.len > 0: lad / "reproos" / "configuration.nim"
    else: getHomeDir() / "reproos-state" / "configuration.nim"
  else:
    "/etc/reproos/configuration.nim"

proc resolveConfigPath(args: ParsedArgs): string =
  if args.configPath.len > 0:
    return args.configPath
  defaultConfigPath()

proc renderTransitionLine(t: SystemTransition): string =
  let sym = case t.kind
            of stAdded: "+"
            of stRemoved: "-"
            of stChanged: "~"
  var line = sym & " " & t.category & " " & t.key
  if t.detail.len > 0:
    line.add "    [" & t.detail & "]"
  line

proc renderDiff(d: SystemConfigDiff2): string =
  if d.transitions.len == 0:
    return "(no transitions)\n"
  var lines: seq[string]
  for t in d.transitions:
    lines.add renderTransitionLine(t)
  lines.join("\n") & "\n"

proc cmdApply(args: ParsedArgs): int =
  let cp = resolveConfigPath(args)
  let cfg = try:
    parseSystemConfigFile(cp)
  except ENoConfig as e:
    stderr.writeLine ToolName & ": " & e.msg
    return 1
  except ESystemConfig as e:
    stderr.writeLine ToolName & ": " & e.msg
    return 1
  var opts: ApplyOptions
  opts.stateDir = args.stateDir
  opts.bootDir = args.bootDir
  opts.runtimeDir = args.runtimeDir
  opts.activationTimestamp = args.activationTs
  opts.skipRealize = args.skipRealize
  # First plan and show the diff.
  var ctx = resolveApplyContext(cfg, opts)
  let desired = buildDesiredManifest(cfg, ctx)
  if manifestsAreEquivalent(ctx.previousManifest, desired):
    echo "no-op: generation " & $ctx.previousManifest.generationNumber &
      " already matches the desired configuration"
    return 0
  let diff = planTransitions(ctx.previousManifest, cfg)
  echo "Planned transitions:"
  echo renderDiff(diff)
  if not args.autoYes:
    stdout.write "Proceed? [y/N] "
    stdout.flushFile()
    let answer = try: readLine(stdin)
                 except EOFError: ""
    if answer.strip().toLowerAscii notin @["y", "yes"]:
      stderr.writeLine ToolName & ": aborted by operator"
      return 3
  # Apply + record. We re-run resolveApplyContext via planApplyRecord
  # because it also handles the no-op short-circuit consistently.
  let recorded = planApplyRecord(cfg, opts)
  echo "Recorded generation " & $recorded.manifest.generationNumber
  echo "  manifest: " & recorded.manifestPath
  echo "  generation dir: " & recorded.generationDir
  echo "  staged-next flag: " & recorded.stagedNextPath
  # Best-effort GRUB regen — write to a sibling dir under the
  # configured boot-dir so test sandboxes see the menu produced. Real
  # ReproOS apply also wires the file into /boot/grub/grub.cfg.
  let bootDir = if opts.bootDir.len > 0: opts.bootDir
                else: recorded.generationDir / ".." / ".." / "boot"
  let bootDirAbs = expandFilename(bootDir)
  let grubDir = bootDirAbs / "grub"
  let grubCfgPath = grubDir / "grub.cfg"
  try:
    createDir(grubDir)
    let inputs = enumerateGenerations(ctx.options.stateDir)
    writeFile(grubCfgPath,
      generateGrubMenu(inputs, recorded.manifest.generationNumber))
    echo "  grub.cfg: " & grubCfgPath
  except OSError as e:
    stderr.writeLine ToolName &
      ": warning: could not write grub.cfg at " & grubCfgPath &
      ": " & e.msg
  0

proc cmdPlan(args: ParsedArgs): int =
  let cp = resolveConfigPath(args)
  let cfg = try:
    parseSystemConfigFile(cp)
  except ENoConfig as e:
    stderr.writeLine ToolName & ": " & e.msg
    return 1
  except ESystemConfig as e:
    stderr.writeLine ToolName & ": " & e.msg
    return 1
  var opts: ApplyOptions
  opts.stateDir = args.stateDir
  opts.bootDir = args.bootDir
  opts.runtimeDir = args.runtimeDir
  let ctx = resolveApplyContext(cfg, opts)
  let desired = buildDesiredManifest(cfg, ctx)
  if manifestsAreEquivalent(ctx.previousManifest, desired):
    echo "no-op"
    return 0
  let diff = planTransitions(ctx.previousManifest, cfg)
  echo renderDiff(diff)
  0

proc cmdList(args: ParsedArgs): int =
  let stateDir = if args.stateDir.len > 0: args.stateDir
                 else:
                   when defined(windows):
                     let lad = getEnv("LOCALAPPDATA")
                     if lad.len > 0: lad / "reproos"
                     else: getHomeDir() / "reproos-state"
                   else:
                     "/var/lib/reproos"
  let current = readCurrentGeneration(stateDir)
  let inputs = enumerateGenerations(stateDir)
  if inputs.len == 0:
    echo "(no generations recorded yet)"
    return 0
  for g in inputs:
    let marker = if g.number == current: " *" else: "  "
    let ts = if g.activationTimeIso.len > 0: g.activationTimeIso
             elif g.activationTimestamp != 0:
               try: fromUnix(g.activationTimestamp).utc.format(
                 "yyyy-MM-dd HH:mm:ss")
               except CatchableError: ""
             else: ""
    echo " " & marker & " generation " & $g.number & "  " & ts
  0

proc cmdConfirm(args: ParsedArgs): int =
  let stateDir = if args.stateDir.len > 0: args.stateDir
                 else:
                   when defined(windows):
                     let lad = getEnv("LOCALAPPDATA")
                     if lad.len > 0: lad / "reproos"
                     else: getHomeDir() / "reproos-state"
                   else:
                     "/var/lib/reproos"
  let outcome = confirmStagedGeneration(stateDir)
  if outcome.promoted:
    echo "confirmed generation " & $outcome.generationNumber
    return 0
  echo "no staged-next generation; current pointer unchanged"
  0

proc cmdGrub(args: ParsedArgs): int =
  let stateDir = if args.stateDir.len > 0: args.stateDir
                 else:
                   when defined(windows):
                     let lad = getEnv("LOCALAPPDATA")
                     if lad.len > 0: lad / "reproos"
                     else: getHomeDir() / "reproos-state"
                   else:
                     "/var/lib/reproos"
  let inputs = enumerateGenerations(stateDir)
  let current = readCurrentGeneration(stateDir)
  let target = if current > 0: current
               else:
                 var best = 0
                 for g in inputs:
                   if g.number > best: best = g.number
                 best
  stdout.write generateGrubMenu(inputs, target)
  0

proc dispatch(): int =
  let args = parseArgs()
  case args.sub
  of "", "help", "--help", "-h":
    echo Usage
    return 0
  of "version", "--version":
    echo ToolName & " " & Version
    return 0
  of "apply": return cmdApply(args)
  of "plan": return cmdPlan(args)
  of "list": return cmdList(args)
  of "confirm": return cmdConfirm(args)
  of "grub": return cmdGrub(args)
  else:
    stderr.writeLine ToolName & ": unknown subcommand '" & args.sub & "'"
    stderr.writeLine Usage
    return 2

when isMainModule:
  quit dispatch()
