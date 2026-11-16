## `repro anywhere --mode addon --host <host> <root@address>`: bootstrap an
## already-booted distribution host into ReproOS add-on mode over SSH
## (ReproOS Add-On Mode §6.5.3).
##
## It has no preflight, bootstrap or apply code of its own. It carries the
## static add-on `repro` (pinned by digest) and the anchor files to a tmpfs
## it mounts at `/run/repro-anywhere` (so nothing the preflight needs is on
## the host's disk; `/run` itself is `noexec` on Debian 13) and runs §6.1's
## preflight there. Plan and apply are separate, as §6.1 and the Anywhere
## safety contract require: without `--expect-plan` the command prints the
## reviewable plan -- the host's preflight report, the canonical text of
## the profile it would apply, the add-on binary's digest and the anchors'
## -- with ONE digest over all of it (`anywherePlanDocument`), and applies
## nothing. With the acknowledged digest it runs the preflight again,
## recomputes the digest from this invocation's inputs and refuses any
## other (a profile changed after the review is refused before anything is
## written), bootstraps with the host's own bootstrap plan digest (§6.2),
## applies the profile's canonical text with the store copy of `repro` that
## bootstrap reports, plans again and requires no change and no drift,
## writes the recipient public key bootstrap generated on the host to
## `--recipient-out` (the registration the producer seals to), and removes
## what it carried.
##
## Every `ssh` / `scp` reads no ssh_config (`-F /dev/null`) and uses the
## exact host key in `--known-hosts` and nothing else
## (`StrictHostKeyChecking=yes`, no global known-hosts file), `BatchMode=yes`
## and no agent forwarding: the Anywhere safety contract's "exact host key"
## (reprobuild-pm `spec/ReproOS-Anywhere-Safety-Contract.md`). Remote
## commands are built from shell-quoted words only.

import std/[json, options, os, osproc, strutils]

import repro_core/ambient_execution
import repro_addon/mutations
from repro_addon/fingerprint import sha256Hex
import repro_profile/types
import repro_addon/host_exec
from repro_addon/image_boot import elfMachineArch
from repro_home_intent/host_identity import selectHost, EHostIdentity
import repro_cli_support/infra
import repro_cli_support/cli_program

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
    expectPlan*: string
      ## The anywhere plan digest the operator acknowledged (spec §6.5.3,
      ## §6.1). "" runs the preflight only, prints the plan and its digest
      ## and applies nothing.
    recipientOut*: string       ## "" => print only
    appliedProfileOut*: string  ## "" => not kept; else the canonical text
                                ## applied, for a later `repro infra plan`
    log*: proc(line: string) {.closure.}

  AnywhereResult* = object
    planDigest*: string         ## the anywhere plan digest (all it applies)
    bootstrapPlanDigest*: string  ## the host preflight's own (§6.1)
    planText*: string           ## the reviewable plan, for plan-only runs
    generationId*: string
    reproExe*: string
    recipientPublicKey*: string
    planReport*: string
    applied*: bool              ## false: the preflight only (no --expect-plan)

const RemoteDir* = "/run/repro-anywhere"

proc fail(step, msg: string) {.noreturn.} =
  raise newException(EAnywhere, "repro anywhere: " & step & ": " & msg)

proc say(o: AnywhereOptions; line: string) =
  if o.log != nil: o.log(line)

proc sshOptions*(o: AnywhereOptions): seq[string] =
  ## The options every `ssh` and `scp` call carries.
  # `-F /dev/null`: no ssh_config is read, so nothing in the operator's
  # configuration (a KnownHostsCommand, a ProxyCommand, another
  # UserKnownHostsFile) can add trust beyond --known-hosts.
  result = @["-F", "/dev/null",
             "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
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

proc fileDigest(path: string): string =
  if path.len == 0: "" else: sha256Hex(readFile(path))

proc anywherePlanDocument*(o: AnywhereOptions; bootstrapPlanDigest: string):
    string =
  ## The canonical text of everything one acknowledged run applies to the
  ## host (spec §6.5.3 step 4, amended 2026-11-13): the host's bootstrap
  ## plan (its digest binds the preflight's inventory and the anchors'
  ## installation), the bootstrap options, the add-on binary, the anchor
  ## files' bytes and the canonical text of the profile applied after
  ## bootstrap. The anywhere plan digest is its SHA-256, so changing any of
  ## them after the review changes the digest.
  var doc = %*{"schema": "reprobuild.anywhere.addon-plan.v1",
    "host": o.host, "target": o.target,
    "bootstrapPlanDigest": bootstrapPlanDigest,
    "bootstrapArgs": bootstrapFlags(o),
    "addonSha256": o.addonSha256,
    "deploySignersSha256": fileDigest(o.deploySigners),
    "cachePublishersSha256": fileDigest(o.cachePublishers),
    "profileSha256": sha256Hex(o.profileText)}
  when mutated("anywhere-digest-omits-profile"):
    # FALSIFYING MUTATION (see repro_addon/mutations.nim): the digest no
    # longer covers the profile, so a profile changed after the review is
    # applied under the acknowledged digest.
    doc.delete("profileSha256")
  $doc

proc anywherePlanDigest*(document: string): string =
  ## The digest an operator acknowledges with `--expect-plan`.
  sha256Hex(document)

proc renderAnywherePlan*(o: AnywhereOptions; preflightReport, document,
                         digest: string): string =
  ## The plan as an operator reviews it: what the host's preflight found
  ## and would bootstrap, the profile text that would then be applied, the
  ## document the digest is taken over, and the digest.
  result = "== the host's preflight (read-only) and bootstrap plan ==\n" &
    preflightReport.strip(leading = false) & "\n" &
    "== the profile applied after bootstrap (canonical text, sha256 " &
    sha256Hex(o.profileText) & ") ==\n" & o.profileText.strip(leading = false) &
    "\n== the plan document (the digest is its SHA-256) ==\n" & document &
    "\nanywhere plan digest: " & digest & "\n"

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
    result.bootstrapPlanDigest = fieldOf(pre.output, "plan digest")
    if pre.exitCode != 0 or result.bootstrapPlanDigest.len == 0:
      fail("preflight", "the host is not compatible (exit " & $pre.exitCode &
        "):\n" & pre.output)
    let document = anywherePlanDocument(o, result.bootstrapPlanDigest)
    result.planDigest = anywherePlanDigest(document)
    o.say("plan digest: " & result.planDigest)
    if o.expectPlan.len == 0:
      # Plan and apply are separate (spec §6.5.3, as approved 2026-11-08
      # and 2026-11-13): nothing is applied until the operator acknowledges
      # this digest, which covers everything the run would apply.
      result.planText = renderAnywherePlan(o, pre.output, document,
                                           result.planDigest)
      o.say("nothing was applied; review the plan and run again with " &
        "--expect-plan " & result.planDigest)
      return
    if o.expectPlan != result.planDigest:
      fail("preflight", "this run's plan is " & result.planDigest &
        ", not the acknowledged " & o.expectPlan & " (the host, the profile, " &
        "the binary or an anchor changed since the review); nothing was " &
        "written")
    # 5. Bootstrap, then the profile through the store copy.
    o.say("bootstrap")
    let boot = mustSsh(o, "bootstrap", remoteCommand(@[remoteRepro, "system",
      "addon", "bootstrap", "--plan", result.bootstrapPlanDigest] & flags))
    result.generationId = fieldOf(boot, "generation")
    result.reproExe = fieldOf(boot, "add-on binary")
    result.recipientPublicKey = fieldOf(boot, "recipient public key")
    if result.reproExe.len == 0:
      fail("bootstrap", "printed no add-on binary path:\n" & boot)
    result.applied = true
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
    when mutated("anywhere-probe-leaves-files"):
      # FALSIFYING MUTATION (see repro_addon/mutations.nim): the clean-up
      # leaves files on disk-backed filesystems the base fingerprint does
      # not cover, which Anywhere Safety Contract §5's add-on exception
      # forbids and only the gate's disk-write listing can see.
      discard ssh(o, "clean up", "mkdir -p /var/lib/repro-anywhere-left && " &
        "touch /var/tmp/repro-anywhere-left /root/.repro-anywhere-left " &
        "/var/lib/repro-anywhere-left/x", 120)

# ---------------------------------------------------------------------------
# The command line.
# ---------------------------------------------------------------------------

proc runAnywhereCli*(conf: ReproCommandLineAnywhere): int =
  ## ``repro anywhere --mode addon ... root@ADDRESS``, its command line parsed
  ## from repro's description (``repro_cli_support/cli_description``).
  var o = AnywhereOptions(addonBinary: conf.addonBinary,
    addonSha256: conf.addonSha256.toLowerAscii(), knownHosts: conf.knownHosts,
    sshKey: conf.sshKey, sshPort: conf.sshPort,
    deploySigners: conf.deploySigners, cachePublishers: conf.cachePublishers,
    cacheUrl: conf.cacheUrl, agentTarget: conf.agentTarget,
    agentSources: conf.manifest, pollIntervalSec: conf.pollInterval,
    expectPlan: conf.expectPlan, recipientOut: conf.recipientOut,
    appliedProfileOut: conf.appliedProfileOut, target: conf.destination)
  let host = conf.host.get("")
  let hostGiven = conf.host.isSome
  let profile = conf.profile
  let homeDir = conf.homeProfileDir
  var arch = conf.arch
  if conf.mode != "addon":
    stderr.writeLine("repro anywhere: --mode addon is the only mode " &
      "(the ReproOS conversion is the reproos repository's anywhere tool)")
    return 2
  let required = [("--profile", profile), ("--addon-binary", o.addonBinary),
                  ("--addon-sha256", o.addonSha256),
                  ("--known-hosts", o.knownHosts), ("root@ADDRESS", o.target)]
  for (name, v) in required:
    if v.len == 0:
      stderr.writeLine("repro anywhere: " & name & " is required; see " &
        "`repro anywhere --help`")
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
    if not r.applied:
      echo "repro anywhere --mode addon: plan only (nothing was applied)"
      echo "  host       : " & o.host & " (" & o.target & ")"
      stdout.write(r.planText)
      echo "  plan digest: " & r.planDigest
      stderr.writeLine("repro anywhere: refusing to apply without an " &
        "acknowledged plan; nothing was written. Review the plan and run " &
        "again with --expect-plan " & r.planDigest)
      return 3
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
