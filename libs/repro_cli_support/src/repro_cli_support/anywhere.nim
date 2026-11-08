## `repro anywhere --mode addon --host <host> <root@address>`: bootstrap an
## already-booted distribution host into ReproOS add-on mode over SSH, in
## one command (ReproOS Add-On Mode §6.5.3).
##
## It has no preflight, bootstrap or apply code of its own. It carries the
## static add-on `repro` (pinned by digest) and the anchor files to a tmpfs
## it mounts at `/run/repro-anywhere` (so nothing the preflight needs is on
## the host's disk; `/run` itself is `noexec` on Debian 13), runs §6.1's
## preflight there, bootstraps with the digest it
## printed (§6.2), applies the profile's canonical text with the store copy
## of `repro` that bootstrap reports, plans again and requires no change and
## no drift, writes the recipient public key bootstrap generated on the
## host to `--recipient-out` (the registration the producer seals to), and
## removes what it carried.
##
## Every `ssh` / `scp` uses the exact host key in `--known-hosts` and
## nothing else (`StrictHostKeyChecking=yes`, no global known-hosts file),
## `BatchMode=yes` and no agent forwarding: the Anywhere safety contract's
## "exact host key" (reprobuild-pm `spec/ReproOS-Anywhere-Safety-Contract.md`).
## Remote commands are built from shell-quoted words only.

import std/[os, osproc, strutils]

import repro_core/ambient_execution
import repro_profile/types
import repro_addon/host_exec
from repro_addon/image_boot import elfMachineArch
from repro_home_intent/host_identity import selectHost, EHostIdentity
import repro_cli_support/infra

type
  EAnywhere* = object of CatchableError
    ## A step failed; the message names it. What bootstrap already did is
    ## undone by `repro system addon uninstall` (§6.4), not here.

  AnywhereOptions* = object
    host*: string
    target*: string             ## `root@<address>`
    sshKey*: string             ## "" => ssh's default identities
    sshPort*: int               ## 0 => 22
    knownHosts*: string         ## the exact host key(s); required
    addonBinary*: string
    addonSha256*: string
    profileText*: string        ## the host profile's canonical text
    deploySigners*: string      ## local anchor files, or ""
    cachePublishers*: string
    cacheUrl*: string
    agentTarget*: string
    agentSources*: seq[string]
    pollIntervalSec*: int
    expectPlan*: string         ## "" => the one-command form
    recipientOut*: string       ## "" => print only
    appliedProfileOut*: string  ## "" => not kept; else the canonical text
                                ## applied, for a later `repro infra plan`
    log*: proc(line: string) {.closure.}

  AnywhereResult* = object
    planDigest*: string
    generationId*: string
    reproExe*: string
    recipientPublicKey*: string
    planReport*: string

const RemoteDir* = "/run/repro-anywhere"

proc fail(step, msg: string) {.noreturn.} =
  raise newException(EAnywhere, "repro anywhere: " & step & ": " & msg)

proc say(o: AnywhereOptions; line: string) =
  if o.log != nil: o.log(line)

proc sshOptions*(o: AnywhereOptions): seq[string] =
  ## The options every `ssh` and `scp` call carries.
  result = @["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
             "-o", "UserKnownHostsFile=" & o.knownHosts,
             "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
             "-o", "ConnectTimeout=30", "-o", "ServerAliveInterval=15"]
  if o.sshKey.len > 0:
    result.add @["-o", "IdentitiesOnly=yes", "-i", o.sshKey]

proc remoteCommand*(words: openArray[string]): string =
  ## One remote shell command from words, each shell-quoted.
  var parts: seq[string]
  for w in words: parts.add quoteShell(w)
  parts.join(" ")

proc sshArgv*(o: AnywhereOptions; remote: string): seq[string] =
  result = @[uncontrolledFindExe("ssh")] & sshOptions(o)
  if o.sshPort > 0: result.add @["-p", $o.sshPort]
  result.add @[o.target, "--", remote]

proc scpArgv*(o: AnywhereOptions; local, remote: string): seq[string] =
  result = @[uncontrolledFindExe("scp"), "-q"] & sshOptions(o)
  if o.sshPort > 0: result.add @["-P", $o.sshPort]
  result.add @[local, o.target & ":" & remote]

proc ssh(o: AnywhereOptions; step, remote: string; timeoutSec = 3600):
    HostToolResult =
  let r = runHostTool(sshArgv(o, remote), mergeStderr = true,
                      timeoutSec = timeoutSec, path = getEnv("PATH"))
  if r.exitCode == 255:
    fail(step, "ssh to " & o.target & " failed (exit 255; check the host " &
      "key in " & o.knownHosts & "):\n" & r.output)
  r

proc mustSsh(o: AnywhereOptions; step, remote: string; timeoutSec = 3600):
    string =
  let r = ssh(o, step, remote, timeoutSec)
  if r.exitCode != 0:
    fail(step, "exited " & $r.exitCode & ":\n" & r.output)
  r.output

proc copy(o: AnywhereOptions; step, local, remote: string) =
  let r = runHostTool(scpArgv(o, local, remote), timeoutSec = 3600,
                      path = getEnv("PATH"))
  if r.exitCode != 0:
    fail(step, "scp " & local & " exited " & $r.exitCode & ":\n" & r.output)

proc fieldOf*(output, label: string): string =
  ## The value of a `<label>: <value>` line (preflight and bootstrap print
  ## their results that way), or "".
  for line in output.splitLines():
    if line.startsWith(label & ":"):
      return line[label.len + 1 .. ^1].strip()
  ""

proc bootstrapFlags(o: AnywhereOptions): seq[string] =
  if o.deploySigners.len > 0:
    result.add @["--deploy-signers", RemoteDir / "deploy-signers.anchors"]
  if o.cachePublishers.len > 0:
    result.add @["--cache-publishers", RemoteDir / "cache-publishers.anchors"]
  if o.cacheUrl.len > 0: result.add @["--cache-url", o.cacheUrl]
  if o.agentTarget.len > 0:
    result.add @["--target", o.agentTarget]
    for s in o.agentSources: result.add @["--manifest", s]
    if o.pollIntervalSec > 0:
      result.add @["--poll-interval", $o.pollIntervalSec]

proc runAnywhereAddon*(o: AnywhereOptions; work: string): AnywhereResult =
  ## The eight steps of §6.5.3. `work` is a local scratch directory.
  if o.knownHosts.len == 0 or not fileExists(o.knownHosts):
    fail("transport", "--known-hosts <file> holding the host's key is required")
  for exe in ["ssh", "scp"]:
    if uncontrolledFindExe(exe).len == 0: fail("transport", exe & " is not on PATH")
  if not fileExists(o.addonBinary):
    fail("binary", "no add-on binary at " & o.addonBinary)
  createDir(work)
  writeFile(work / "profile.txt", o.profileText)
  let remoteRepro = RemoteDir / "repro"

  # 3. Carry the binary and anchors to a tmpfs of the command's own, mounted
  # at /run/repro-anywhere: nothing the preflight needs is on the host's
  # disk, and the distribution mounts /run itself `noexec` (Debian 13).
  o.say("carrying the add-on binary to " & o.target & ":" & RemoteDir)
  let fsType = mustSsh(o, "transport", remoteCommand(["findmnt", "-n", "-o",
    "FSTYPE", "--target", "/run"])).strip()
  if fsType != "tmpfs":
    fail("transport", "/run on the host is " & fsType & ", not a tmpfs; " &
      "the preflight's inputs must not touch the host's disk")
  discard mustSsh(o, "transport", "if mountpoint -q " & quoteShell(RemoteDir) &
    "; then umount " & quoteShell(RemoteDir) & "; fi; rm -rf " &
    quoteShell(RemoteDir) & " && mkdir -m 0700 " & quoteShell(RemoteDir) &
    " && mount -t tmpfs -o mode=0700,size=512m,nosuid,nodev repro-anywhere " &
    quoteShell(RemoteDir))
  copy(o, "transport", o.addonBinary, remoteRepro)
  for (local, name) in [(o.deploySigners, "deploy-signers.anchors"),
                        (o.cachePublishers, "cache-publishers.anchors")]:
    if local.len > 0: copy(o, "transport", local, RemoteDir / name)
  copy(o, "transport", work / "profile.txt", RemoteDir / "profile.txt")
  discard mustSsh(o, "binary digest", "cd " & quoteShell(RemoteDir) &
    " && echo " & quoteShell(o.addonSha256 & "  repro") &
    " | sha256sum -c - && chmod 0755 repro")
  let flags = bootstrapFlags(o)
  try:
    # 4. The preflight.
    o.say("preflight")
    let pre = ssh(o, "preflight",
      remoteCommand(@[remoteRepro, "system", "addon", "preflight"] & flags))
    result.planDigest = fieldOf(pre.output, "plan digest")
    if pre.exitCode != 0 or result.planDigest.len == 0:
      fail("preflight", "the host is not compatible (exit " & $pre.exitCode &
        "):\n" & pre.output)
    o.say("plan digest: " & result.planDigest)
    if o.expectPlan.len > 0 and o.expectPlan != result.planDigest:
      fail("preflight", "the host's plan is " & result.planDigest &
        ", not the expected " & o.expectPlan & "; nothing was written")
    # 5. Bootstrap, then the profile through the store copy.
    o.say("bootstrap")
    let boot = mustSsh(o, "bootstrap", remoteCommand(@[remoteRepro, "system",
      "addon", "bootstrap", "--plan", result.planDigest] & flags))
    result.generationId = fieldOf(boot, "generation")
    result.reproExe = fieldOf(boot, "add-on binary")
    result.recipientPublicKey = fieldOf(boot, "recipient public key")
    if result.reproExe.len == 0:
      fail("bootstrap", "printed no add-on binary path:\n" & boot)
    o.say("apply")
    let applied = mustSsh(o, "apply", remoteCommand([result.reproExe, "infra",
      "apply", "--profile", RemoteDir / "profile.txt"]))
    result.generationId = block:
      var g = ""
      for line in applied.splitLines():
        if line.startsWith("generation "):
          g = line.split(' ')[1]
      if g.len > 0: g else: result.generationId
    # 6. Plan again: nothing to do.
    o.say("plan")
    result.planReport = mustSsh(o, "plan", remoteCommand([result.reproExe,
      "infra", "plan", "--profile", RemoteDir / "profile.txt"]))
    if "ledger diff: no change" notin result.planReport or
        "service transitions: none" notin result.planReport:
      fail("plan", "the plan after the apply still predicts changes:\n" &
        result.planReport)
    if o.appliedProfileOut.len > 0:
      writeFile(o.appliedProfileOut, o.profileText)
    # 7. Register the recipient key.
    if o.recipientOut.len > 0 and result.recipientPublicKey.len > 0:
      createDir(parentDir(o.recipientOut.absolutePath))
      writeFile(o.recipientOut, result.recipientPublicKey & "\n")
      o.say("recipient public key written to " & o.recipientOut)
  finally:
    # 8. Remove what was carried, whatever happened.
    discard ssh(o, "clean up", "umount " & quoteShell(RemoteDir) &
      "; rmdir " & quoteShell(RemoteDir), 120)

# ---------------------------------------------------------------------------
# The command line.
# ---------------------------------------------------------------------------

const AnywhereUsage* = """usage: repro anywhere --mode addon --host NAME --profile FILE
         --addon-binary FILE --addon-sha256 HEX --known-hosts FILE
         [--ssh-key FILE] [--ssh-port N] [--arch amd64|arm64|armhf]
         [--deploy-signers FILE] [--cache-publishers FILE] [--cache-url URL]
         [--agent-target T --manifest URL...] [--poll-interval S]
         [--expect-plan DIGEST] [--recipient-out FILE]
         [--applied-profile-out FILE]
         [--home-profile-dir DIR] root@ADDRESS
  Bootstrap an already-booted distribution host into ReproOS add-on mode
  over SSH in one command (ReproOS Add-On Mode §6.5.3): the read-only
  preflight, bootstrap with the digest it printed, the profile's apply and
  a plan that must predict nothing. Options a profile's baseOs.bootstrap
  declares are its defaults.
"""

proc runAnywhereCli*(args: seq[string]): int =
  var o = AnywhereOptions()
  var mode, host, profile, homeDir, arch: string
  var hostGiven = false
  var i = 0
  try:
    while i < args.len:
      let a = args[i]
      template value(): string =
        if "=" in a: a.split('=', 1)[1]
        elif i + 1 < args.len:
          inc i
          args[i]
        else:
          raise newException(ValueError, a & " requires a value")
      let flag = if a.startsWith("--"): a.split('=', 1)[0] else: a
      case flag
      of "-h", "--help":
        stdout.write(AnywhereUsage)
        return 0
      of "--mode": mode = value()
      of "--host": host = value(); hostGiven = true
      of "--profile": profile = value()
      of "--addon-binary": o.addonBinary = value()
      of "--addon-sha256": o.addonSha256 = value().toLowerAscii()
      of "--known-hosts": o.knownHosts = value()
      of "--ssh-key": o.sshKey = value()
      of "--ssh-port": o.sshPort = parseInt(value())
      of "--arch": arch = value()
      of "--deploy-signers": o.deploySigners = value()
      of "--cache-publishers": o.cachePublishers = value()
      of "--cache-url": o.cacheUrl = value()
      of "--agent-target": o.agentTarget = value()
      of "--manifest": o.agentSources.add value()
      of "--poll-interval": o.pollIntervalSec = parseInt(value())
      of "--expect-plan": o.expectPlan = value()
      of "--recipient-out": o.recipientOut = value()
      of "--applied-profile-out": o.appliedProfileOut = value()
      of "--home-profile-dir": homeDir = value()
      else:
        if a.startsWith("-"): raise newException(ValueError, "unknown flag: " & a)
        if o.target.len > 0:
          raise newException(ValueError, "one target only, got " & a)
        o.target = a
      inc i
    if mode != "addon":
      raise newException(ValueError, "--mode addon is the only mode " &
        "(the ReproOS conversion is the reproos repository's anywhere tool)")
    for (name, v) in [("--profile", profile), ("--addon-binary", o.addonBinary),
                      ("--addon-sha256", o.addonSha256),
                      ("--known-hosts", o.knownHosts), ("root@ADDRESS", o.target)]:
      if v.len == 0: raise newException(ValueError, name & " is required")
  except ValueError as e:
    stderr.write("repro anywhere: " & e.msg & "\n" & AnywhereUsage)
    return 2
  try:
    o.host = selectHost(host, hostGiven).name
  except EHostIdentity as e:
    stderr.writeLine("repro anywhere: " & e.msg)
    return 2
  if not fileExists(profile):
    stderr.writeLine("repro anywhere: no system profile at " & profile)
    return 1
  # The add-on binary names the target's architecture; runtime predicates
  # are evaluated for it.
  if arch.len == 0 and fileExists(o.addonBinary):
    arch = elfMachineArch(readFile(o.addonBinary)[0 ..< 64])
  let profilePath = profile.absolutePath
  var baseOs: BaseOsIntent
  if not compileForTarget("repro anywhere", o.host, profilePath, homeDir, arch,
                          o.profileText, baseOs):
    return 1
  if baseOs.declared:
    let bs = baseOs.bootstrap
    let dir = profilePath.parentDir
    if o.deploySigners.len == 0 and bs.deploySigners.len > 0:
      o.deploySigners = dir / bs.deploySigners
    if o.cachePublishers.len == 0 and bs.cachePublishers.len > 0:
      o.cachePublishers = dir / bs.cachePublishers
    if o.cacheUrl.len == 0: o.cacheUrl = bs.cacheUrl
    if o.agentTarget.len == 0 and bs.agentTarget.len > 0:
      o.agentTarget = bs.agentTarget
      o.agentSources = bs.agentSources
      if o.pollIntervalSec == 0: o.pollIntervalSec = bs.pollIntervalSec
  o.log = proc(line: string) = stderr.writeLine("repro anywhere: " & line)
  let xdg = getEnv("XDG_CACHE_HOME")
  let work = (if xdg.len > 0: xdg else: getHomeDir() / ".cache") /
    "reprobuild" / "anywhere" / (o.host & "-" & $getCurrentProcessId())
  try:
    let r = runAnywhereAddon(o, work)
    echo "repro anywhere --mode addon"
    echo "  host       : " & o.host & " (" & o.target & ")"
    echo "  plan digest: " & r.planDigest
    echo "  generation : " & r.generationId
    echo "  repro      : " & r.reproExe
    echo "  recipient  : " & r.recipientPublicKey &
      (if o.recipientOut.len > 0: " (written to " & o.recipientOut & ")" else: "")
    echo "  plan       : no change, no drift"
    stdout.write(r.planReport)
    return 0
  except EAnywhere as e:
    stderr.writeLine(e.msg)
    return 1
  finally:
    try: removeDir(work)
    except OSError: discard
