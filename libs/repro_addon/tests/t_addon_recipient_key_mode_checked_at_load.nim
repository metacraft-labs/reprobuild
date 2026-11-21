## Gate ``t_addon_recipient_key_mode_checked_at_load`` (milestone A7;
## ReproOS Add-On Mode spec §10.3; threat model G4, T21).
##
## The recipient key is the one secret at rest on an add-on host, and it
## opens every envelope ever sealed to it. A key that group or others can
## read, or that another user owns, may have been copied: it is refused
## with ``aoSecretsFailed`` BEFORE any envelope is opened, and the same key
## at ``0400`` owned by the required user opens the envelope.
##
## The cases, on real files under a temporary directory, through the
## production code paths:
##
## 1. ``0644``: ``loadRecipientKeyChecked`` refuses, naming the mode; the
##    re-materialisation the apply and the boot unit run
##    (``materialiseFromRetained``) refuses with nothing materialised; and
##    the deploy agent's tick, given a manifest with a sealed section,
##    reports ``aoSecretsFailed`` through the add-on's sink;
## 2. ``0440`` (group-readable only) and ``0600`` (owner-writable): the
##    first refused, the second accepted -- only access by group or others
##    matters;
## 3. another owner: the file's owner is not the one the layout requires.
##    As root the key is ``chown``-ed to ``nobody``; as an ordinary user
##    the layout requires a uid that is not ours (a file owned by someone
##    else cannot be created without privilege);
## 4. a symbolic link at the key's path is refused;
## 5. positive control: the same key at ``0400`` opens the envelope, and
##    the tick applies (``aoApplied``).
##
## *Falsifying mutation*: ``-d:reproAddonMutation=recipient-key-mode-unchecked``
## removes the check; case 1 then opens the envelope and this test fails.
## Run it with ``scripts/run_addon_unit_mutation.sh
## t_addon_recipient_key_mode_checked_at_load recipient-key-mode-unchecked``.
##
## *Mocking.* The deploy agent's apply hook is a recording proc: this gate
## is about the sealed section, which the tick handles before the apply,
## and a real add-on switch needs root and a bootstrapped host (the VM
## gates run that path). Everything else is the real code on real files.

import std/[os, posix, strutils, unittest]

import repro_infra/profile
import repro_deploy_agent/[agent, manifest, secrets]
import repro_peer_cache/auth as peerAuth

import repro_addon/addon_secrets
import repro_addon/secrets_ops

proc bytesOf(s: string): seq[byte] =
  for ch in s: result.add(byte(ch))

const Target = "addon-key-gate"

type Bed = object
  root: string
  layout: SecretsLayout
  stateDir: string
  pub: PublicKeyBytes

proc newBed(name: string): Bed =
  result.root = getTempDir() / ("repro-addon-keymode-" & name & "-" &
                                $getCurrentProcessId())
  removeDir(result.root)
  createDir(result.root)
  let agentDir = result.root / "agent"
  doAssert posix.mkdir(agentDir.cstring, Mode(0o700)) == 0
  result.layout = SecretsLayout(agentDir: agentDir,
    runDir: result.root / "run" / "secrets", owner: int(geteuid()),
    fs: sfAny)
  result.stateDir = result.root / "state"
  createDir(result.stateDir)
  let key = ensureRecipientKeyFile(recipientKeyPath(result.layout))
  doAssert key.created
  result.pub = key.publicKey

proc retainCanary(b: Bed) =
  writeRetained(b.layout, RetainedEnvelope(target: Target,
    sealed: sealSecrets(b.pub, Target, @[SecretFile(path: "web/token",
      mode: 0o400, content: bytesOf("canary-7f3a"))], noRevokedRecipientKeys("test"))))

const Decls = [SecretFileDecl(service: "web", name: "token")]

proc materialisedToken(b: Bed): string =
  let p = b.layout.runDir / "web" / "token"
  if fileExists(p): readFile(p) else: ""

proc tick(b: Bed): AgentOutcome =
  ## One deploy-agent tick with the add-on's sink, reading a signed v2
  ## manifest from a file.
  let signer = peerAuth.generateKeypair()
  var m = DeployManifest(target: Target, sequence: 1, deploymentId: "d1",
    profileText: "", hasSecrets: true,
    secrets: sealSecrets(b.pub, Target, @[SecretFile(path: "web/token",
      mode: 0o400, content: bytesOf("canary-7f3a"))], noRevokedRecipientKeys("test")))
  signManifest(signer, m)
  let src = b.root / "manifest.rdmf"
  let enc = encodeManifest(m)
  var s = newString(enc.len)
  for i, x in enc: s[i] = char(x)
  writeFile(src, s)
  var cfg = AgentConfig(target: Target, sources: @[src],
    anchors: anchorsFromKeypairs([signer.publicKey]),
    stateDir: b.root / "agent-state")
  let layout = b.layout
  let stateDir = b.stateDir
  cfg.secretsSink = proc(m: DeployManifest): string {.gcsafe.} =
    {.cast(gcsafe).}:
      acceptSealedSection(stateDir, layout, m)
  var deps: AgentDeps
  deps.apply = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
    (true, "recorded")
  runAgentTick(cfg, deps)

suite "t_addon_recipient_key_mode_checked_at_load":
  test "a 0644 key is refused before any envelope is opened":
    let b = newBed("0644")
    defer: removeDir(b.root)
    b.retainCanary()
    doAssert posix.chmod(recipientKeyPath(b.layout).cstring, Mode(0o644)) == 0
    var msg = ""
    try:
      discard loadRecipientKeyChecked(recipientKeyPath(b.layout), b.layout.owner)
    except AddonSecretsFailed as e:
      msg = e.msg
    check "aoSecretsFailed" in msg
    check "group or others" in msg and "0644" in msg
    expect AddonSecretsFailed:
      discard materialiseFromRetained(b.layout, Decls)
    check b.materialisedToken() == ""
    let o = b.tick()
    check o.kind == aoSecretsFailed
    check "group or others" in o.message
    # The envelope was not retained over the old one either: nothing was
    # accepted with an unusable key.

  test "group read alone is refused; owner write is not access by others":
    let b = newBed("0440")
    defer: removeDir(b.root)
    b.retainCanary()
    doAssert posix.chmod(recipientKeyPath(b.layout).cstring, Mode(0o440)) == 0
    expect AddonSecretsFailed:
      discard materialiseFromRetained(b.layout, Decls)
    doAssert posix.chmod(recipientKeyPath(b.layout).cstring, Mode(0o600)) == 0
    check materialiseFromRetained(b.layout, Decls) == @["web"]
    check b.materialisedToken() == "canary-7f3a"

  test "a key owned by another user is refused":
    let b = newBed("owner")
    defer: removeDir(b.root)
    b.retainCanary()
    var msg = ""
    if geteuid() == 0:
      # Root can give the key away for real; the layout requires root.
      doAssert posix.chown(recipientKeyPath(b.layout).cstring, Uid(65534),
                           Gid(65534)) == 0
      try:
        discard materialiseFromRetained(b.layout, Decls)
      except AddonSecretsFailed as e:
        msg = e.msg
      check b.materialisedToken() == ""
    else:
      # A file owned by someone else cannot be made without privilege: the
      # key stays ours and the load requires another uid.
      try:
        discard loadRecipientKeyChecked(recipientKeyPath(b.layout),
                                        int(getuid()) + 1)
      except AddonSecretsFailed as e:
        msg = e.msg
    check "aoSecretsFailed" in msg and "is owned by uid" in msg

  test "a symbolic link at the key's path is refused":
    let b = newBed("link")
    defer: removeDir(b.root)
    b.retainCanary()
    let real = b.layout.agentDir / "elsewhere.key"
    moveFile(recipientKeyPath(b.layout), real)
    createSymlink(real, recipientKeyPath(b.layout))
    var msg = ""
    try:
      discard loadRecipientKeyChecked(recipientKeyPath(b.layout), b.layout.owner)
    except AddonSecretsFailed as e:
      msg = e.msg
    check "symbolic link" in msg

  test "a FIFO at the key's path is refused without blocking":
    let b = newBed("fifo")
    defer: removeDir(b.root)
    removeFile(recipientKeyPath(b.layout))
    doAssert mkfifo(recipientKeyPath(b.layout).cstring, Mode(0o400)) == 0
    var msg = ""
    try:
      discard loadRecipientKeyChecked(recipientKeyPath(b.layout), b.layout.owner)
    except AddonSecretsFailed as e:
      msg = e.msg
    check "not a regular file" in msg

  test "positive control: the same key at 0400 opens the envelope":
    let b = newBed("0400")
    defer: removeDir(b.root)
    b.retainCanary()
    check (getFilePermissions(recipientKeyPath(b.layout)) * {fpGroupRead,
      fpOthersRead}).len == 0
    check materialiseFromRetained(b.layout, Decls) == @["web"]
    check b.materialisedToken() == "canary-7f3a"
    let o = b.tick()
    check o.kind == aoApplied
