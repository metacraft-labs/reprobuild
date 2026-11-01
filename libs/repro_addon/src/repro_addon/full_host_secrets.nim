## Secrets on a host whose system profile is realised in full (a ReproOS
## host, `system: {mode: full, ...}`): the same secrets an add-on host has,
## through the same library.
##
## A `secrets.secretFile` declaration and a unit's `credentials` render the
## same `LoadCredential=<name>:/run/repro/secrets/<service>/<name>` line on
## both realisations (the unit renderer is shared), so a full host must put
## the same bytes at the same path or the unit it was given cannot start.
## Nothing here is a second implementation: the key is the deploy agent's
## recipient key (`ensureRecipientKeyFile`), the envelope is the add-on's
## retained envelope (`addon_secrets`: sealed to that key, opened only in a
## buffer locked in RAM), and materialisation is `materialiseFromEnvelope`
## with every property its gates hold -- a ramfs under `/run/repro/secrets`,
## each file born `0400` root inside a `0700` directory, never written
## through a link, undeclared entries removed.
##
## What differs from an add-on host is only what a full host does not have:
## no ownership ledger, no add-on generations and so no per-generation
## envelope copies. A full host keeps one envelope, the latest
## (`/var/lib/repro/agent/sealed-secrets`), and every `repro infra apply`
## materialises the profile's declarations from it before any unit starts.
##
## *At boot.* The ramfs is empty after a reboot. Every unit that loads
## credentials wants and is ordered after `repro-addon-secrets.service`
## (the renderer's `SecretsOrderingUnit`, the same on both realisations),
## and on a full host the apply installs that unit itself
## (`fullHostSecretsUnit`): a bounded oneshot that re-materialises the
## declarations the last apply recorded (`FullHostDeclsPath`) from the
## latest envelope, as an add-on host's boot secrets unit does.
##
##   repro system secret put --service S --name N [--target T] < bytes
##       On a full host: create the recipient key if there is none, seal the
##       secret from stdin into the latest envelope. On an add-on host the
##       verb is `repro system addon secret put`, and this one hands over to
##       it.

import std/[algorithm, os, strutils]

import repro_infra

import repro_deploy_agent/secrets as agentSecrets
import repro_peer_cache/auth as peerAuth

from ./addon_apply import DefaultStateDir
from ./generation0 import NoSwapLine, SecretsUnitTimeoutSec
import ./switch
import ./host_exec
import ./addon_secrets
import ./locked_buffer
import ./secrets_ops

proc ensureFullHostRecipientKey*(l: SecretsLayout): bool =
  ## The host's recipient key, created (0400 root, in a 0700 directory) when
  ## there is none. True when it was created now. The public half is written
  ## beside it the way bootstrap writes it, so a producer can seal to it.
  let key = ensureRecipientKeyFile(recipientKeyPath(l))
  result = key.created
  let pubPath = recipientPubPath(l)
  if not fileExists(pubPath):
    writeFile(pubPath, peerAuth.publicKeyHex(key.publicKey) & "\n")
    setFilePermissions(pubPath, {fpUserRead, fpGroupRead, fpOthersRead})

proc fullHostSecretPut*(stateDir: string; l: SecretsLayout;
                        service, name: string; content: LockedBytes;
                        target = ""): seq[string] =
  ## Seal ``content`` as the entry ``<service>/<name>`` into the latest
  ## envelope, to this host's recipient key (other entries are kept). It is
  ## materialised by the next `repro infra apply`, which reads the
  ## declarations from the profile it applies; a put does not restart
  ## anything on a full host, because which unit reads the entry is only
  ## known to that apply.
  if not isSafeSecretComponent(service) or not isSafeSecretComponent(name):
    raise newException(AddonSecretsFailed, "secret put: --service and " &
      "--name must each be one path segment of letters, digits, '.', '-' " &
      "or '_', at most 64 bytes, not starting with '.'")
  guardPlaintext(l)
  withSecretsLocks(stateDir, "repro system secret put"):
    if ensureFullHostRecipientKey(l):
      result.add("created the recipient key " & recipientKeyPath(l))
    let entry = secretEntryPath(service, name)
    let tgt = addEntry(l, latestEnvelopePath(l), entry, content, target,
                       createIfAbsent = true)
    result.add("sealed " & entry & " into " & latestEnvelopePath(l) &
               " (target " & tgt & ")")

proc materialiseFullHostSecrets*(l: SecretsLayout;
                                 decls: openArray[SecretFileDecl]):
    seq[string] =
  ## Make `/run/repro/secrets` hold exactly ``decls`` from the latest
  ## envelope; returns the services whose secrets changed. A profile that
  ## declares no secret clears whatever an earlier one left, and needs no
  ## key; one that does refuses (``AddonSecretsFailed``) when the key, the
  ## envelope or an entry is missing, before any unit is touched.
  if decls.len == 0 and not dirExists(l.hostRoot & l.runDir):
    return @[]
  result = materialiseFromEnvelope(l, decls, latestEnvelopePath(l))
  result.sort()

proc consumersOf*(units: openArray[tuple[name: string; credentials: seq[string]]];
                  changedServices: openArray[string]): seq[string] =
  ## The units whose credentials changed: a unit named `<service>.service`
  ## that loads at least one credential, for each changed service (the
  ## renderer derives the secret's service from the unit's name the same
  ## way, `credentialServiceOf`).
  for u in units:
    if u.credentials.len == 0: continue
    let svc = credentialServiceOf(u.name)
    if svc.len > 0 and svc in changedServices and u.name notin result:
      result.add(u.name)
  result.sort()

proc runFullHostSecretPutCli*(args: seq[string]): int =
  ## ``repro system secret put --service S --name N [--target T]`` on a host
  ## realised in full; the secret is read from stdin, byte for byte, into a
  ## buffer locked in RAM, in a process whose heap cannot be swapped.
  if args.len == 0 or args[0] != "put":
    stderr.write("usage: repro system secret put --service S --name N " &
      "[--target T] < secret\n")
    return 2
  var service, name, target = ""
  var i = 1
  while i < args.len:
    let a = args[i]
    if i + 1 >= args.len or a notin ["--service", "--name", "--target"]:
      stderr.write("repro system secret put: unknown or incomplete option " &
        a & "\n")
      return 2
    case a
    of "--service": service = args[i + 1]
    of "--name": name = args[i + 1]
    else: target = args[i + 1]
    i += 2
  if service.len == 0 or name.len == 0:
    stderr.write("repro system secret put: --service and --name are " &
      "required\n")
    return 2
  let reexec = reexecInNoSwapScope()
  if reexec >= 0: return reexec
  let layout = defaultSecretsLayout()
  try:
    guardPlaintext(layout)   # before the plaintext is read
    let content = readLockedFd(layout, 0, "the secret on stdin")
    if content.len == 0:
      stderr.write("repro system secret put: no secret on stdin\n")
      return 2
    for line in fullHostSecretPut(DefaultStateDir, layout, service, name,
                                  content, target):
      stdout.write(line & "\n")
    0
  except CatchableError as e:
    stderr.write("repro system secret put: " & e.msg & "\n")
    1

const
  FullHostDeclsPath* = "/var/lib/repro/agent/full-host-secrets"
    ## The declarations the last apply materialised, one `<service>/<name>`
    ## per line (0600 root): what the boot unit re-materialises.
  FullHostSecretsUnitPath* = "/etc/systemd/system/" & SecretsBootUnit

proc fullHostSecretsUnit*(reproExe: string): string =
  ## The boot-time secrets unit of a host realised in full. Like the
  ## add-on's (`generation0.secretsUnit`) it is on the boot path of every
  ## unit that loads credentials, so it is bounded, needs no network and
  ## never fails the boot: a secret it cannot materialise is reported and
  ## the unit that loads it fails to start.
  "[Unit]\n" &
    "Description=Reprobuild secrets for this boot (system realised in full)\n" &
    "After=local-fs.target\n" &
    "\n[Service]\n" &
    "Type=oneshot\n" &
    "RemainAfterExit=yes\n" &
    "TimeoutStartSec=" & $SecretsUnitTimeoutSec & "s\n" &
    "ExecStart=/bin/sh -c 'if [ -x " & reproExe & " ]; then exec " &
      reproExe & " system secret materialise --boot; else echo repro " &
      "secrets: degraded: " & reproExe & " is unavailable; fi'\n" &
    "PrivateNetwork=yes\n" &
    "NoNewPrivileges=yes\n" &
    "ProtectHome=yes\n" &
    "PrivateTmp=yes\n" &
    NoSwapLine &
    "\n[Install]\n" &
    "WantedBy=multi-user.target\n"

proc renderDecls*(decls: openArray[SecretFileDecl]): string =
  for d in decls: result.add(secretEntryPath(d.service, d.name) & "\n")

proc parseDecls*(text: string): seq[SecretFileDecl] =
  ## The inverse of `renderDecls`; a line that is not one safe
  ## `<service>/<name>` raises.
  for line in text.splitLines():
    let t = line.strip()
    if t.len == 0: continue
    let parts = t.split('/')
    if parts.len != 2 or not isSafeSecretComponent(parts[0]) or
        not isSafeSecretComponent(parts[1]):
      raise newException(AddonSecretsFailed, FullHostDeclsPath &
        ": not a secret entry: " & t)
    result.add(SecretFileDecl(service: parts[0], name: parts[1]))

proc recordFullHostSecrets*(decls: openArray[SecretFileDecl];
                            reproExe: string; declsPath = FullHostDeclsPath;
                            unitPath = FullHostSecretsUnitPath): seq[string] =
  ## After an apply materialised ``decls``: record them for the boot unit,
  ## and install and enable that unit when its bytes changed. Returns what
  ## it did. With no declaration the record is emptied and the unit stays
  ## (it then clears nothing and materialises nothing).
  createDir(parentDir(declsPath))
  let text = renderDecls(decls)
  if not fileExists(declsPath) or readFile(declsPath) != text:
    writeFile(declsPath & ".tmp", text)
    setFilePermissions(declsPath & ".tmp", {fpUserRead, fpUserWrite})
    moveFile(declsPath & ".tmp", declsPath)
    result.add("recorded " & $decls.len & " secret declaration(s)")
  if decls.len == 0 and not fileExists(unitPath): return
  let unit = fullHostSecretsUnit(reproExe)
  if not fileExists(unitPath) or readFile(unitPath) != unit:
    writeFile(unitPath & ".tmp", unit)
    setFilePermissions(unitPath & ".tmp",
                       {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
    moveFile(unitPath & ".tmp", unitPath)
    daemonReload()
    let r = runSystemctl(["enable", "--", SecretsBootUnit])
    if r.exitCode != 0:
      raise newException(AddonSecretsFailed, "enabling " & SecretsBootUnit &
        " failed: " & r.output.strip())
    result.add("installed " & unitPath)

proc bootFullHostSecrets*(l = defaultSecretsLayout();
                          declsPath = FullHostDeclsPath): string =
  ## The boot unit's work: re-materialise the recorded declarations from
  ## the latest envelope. Never raises: it reports.
  try:
    let decls = if fileExists(declsPath): parseDecls(readFile(declsPath))
                else: @[]
    let changed = materialiseFullHostSecrets(l, decls)
    "repro secrets: ok: " & $decls.len & " declared, materialised for " &
      (if changed.len > 0: changed.join(", ") else: "none")
  except CatchableError as e:
    "repro secrets: degraded: " & e.msg

proc runFullHostSecretMaterialiseCli*(args: seq[string]): int =
  ## ``repro system secret materialise --boot``: the boot unit's verb.
  if args.len != 1 or args[0] != "--boot":
    stderr.write("usage: repro system secret materialise --boot\n")
    return 2
  let reexec = reexecInNoSwapScope()
  if reexec >= 0: return reexec
  stdout.write(bootFullHostSecrets() & "\n")
  0
