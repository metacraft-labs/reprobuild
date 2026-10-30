## The add-on's read-only preflight.
##
## Before bootstrap writes anything, the preflight inventories the host and
## decides whether the add-on may be installed on it. It follows the
## discipline of the ReproOS Anywhere preflight: it only reads (files,
## ``/proc``, ``statfs``, and ``systemctl --version``), its checks are a
## closed set with ``pass`` / ``fail`` verdicts, and its result is a
## canonical JSON plan identified by its SHA-256. The operator acknowledges
## that digest -- ``repro system addon bootstrap --plan <digest>`` -- not a
## boolean ``--confirm``, and bootstrap recomputes the plan on the host and
## refuses unless it is the same plan, byte for byte.
##
## The plan covers exactly what the decision depends on: the base (os-release
## identity, userspace architecture, PID 1, the systemd version), the host
## identity (so a plan cannot be replayed on another machine), the root
## filesystem type, every check's verdict, the bootstrap binary's digest, the
## trust anchors, and generation 0 (its object list and profile digest).
## Values that change on their own between two reads -- free space, whether
## the root happens to be mounted read-only at this moment -- appear only as
## verdicts, never as numbers, so the digest is stable between the preflight
## and the bootstrap that follows it.
##
## Zero-write is enforced by the gate, not merely claimed here:
## ``e2e_addon_preflight_is_zero_write`` runs this preflight in a guest whose
## disk is write-protected below the guest (QEMU ``readonly=on``) and
## compares the disk image byte for byte afterwards.

import std/[algorithm, json, os, posix, strutils, tables]

import repro_core
import repro_peer_cache/auth as peerAuth

import ./fingerprint
import ./generation0
import ./host_exec
import ./linux_fs
import ./mutations
import ./store_root

type
  Verdict* = enum
    vPass = "pass"
    vFail = "fail"

  PreflightCheck* = object
    id*: string
    verdict*: Verdict
    detail*: string

  PreflightInputs* = object
    deploySignersPath*: string     ## "" => empty anchor set
    cachePublishersPath*: string   ## "" => empty anchor set
    cacheUrl*: string              ## "" => no binary cache
    binaryPath*: string            ## "" => /proc/self/exe

  KeptFile* = object
    ## A file bootstrap keeps as found. A content-pinned input (the signers
    ## file, the tmpfiles fragment, the recipient key pair) is bound into
    ## the plan by its digest and ledgered with it; an agent record (the
    ## sequence floor, the tick files) is rewritten by the deploy agent at
    ## every tick, so it is kept by path with its content unpinned.
    path*: string
    sha256*: string           ## "" when the content is unpinned
    pinned*: bool

  PreBootstrapInputs* = object
    ## Reprobuild's own pre-bootstrap inputs the preflight found on the
    ## host and bootstrap takes over (spec §6.1): a host stood up with the
    ## deploy agent before the add-on bootstraps it already carries them,
    ## and they are not foreign occupants.
    roots*: seq[string]       ## existing directories, parents before children
    keptFiles*: seq[KeptFile] ## files bootstrap leaves as found
    signersFile*: string      ## PreBootstrapSignersPath when kept, else ""
    signersKeys*: seq[string] ## its keys, canonical (parseAnchorKeys)
    recipientKey*: string     ## RecipientKeyPath when kept, else ""
    recipientPublicKey*: string ## the kept key's public half (hex), else ""
    tmpfilesFragment*: string ## PreBootstrapTmpfilesPath when kept, else ""

  OccupancyReport* = object
    inputs*: PreBootstrapInputs
    refused*: seq[string]     ## ``<path>: <why>``, sorted; empty => pass

  PreflightReport* = object
    checks*: seq[PreflightCheck]
    compatible*: bool
    planJson*: string        ## canonical
    digest*: string          ## sha256 of planJson
    binarySha256*: string
    gen0*: seq[OwnObject]
    gen0Inputs*: Gen0Inputs
    rootFsType*: string
    preBootstrap*: PreBootstrapInputs

  OsRelease* = Table[string, string]

  SupportedBase* = object
    id*: string
    versionId*: string
    note*: string

const
  PlanSchema* = "reprobuild.addon.plan.v1"

  SupportedBases* = [
    # The A0 base matrix (decided 2026-10-30): Debian 13 including Raspberry
    # Pi OS 13, and Ubuntu 24.04. Debian 12 is accepted as the source side of
    # the 12 -> 13 release-upgrade gate.
    SupportedBase(id: "debian", versionId: "13", note: "supported"),
    SupportedBase(id: "raspbian", versionId: "13", note: "supported"),
    SupportedBase(id: "ubuntu", versionId: "24.04", note: "supported"),
    # Ubuntu 26.04 joins the matrix with the 24.04 -> 26.04 release-upgrade
    # gate that covers it (spec §6.1, milestone A10).
    SupportedBase(id: "ubuntu", versionId: "26.04", note: "supported"),
    SupportedBase(id: "debian", versionId: "12",
                  note: "release-upgrade source"),
  ]

  SupportedBaseList* = "debian 13, raspbian 13, ubuntu 24.04, ubuntu 26.04; " &
                       "debian 12 as release-upgrade source"
    ## The matrix as one phrase, for refusals.

  SupportedArchitectures* = ["amd64", "arm64", "armhf"]

  MinimumFreeBytes* = 512'u64 * 1024 * 1024

  AddonOwnedRoots* = [ReproRoot, "/etc/repro", "/var/lib/repro", "/run/repro"]

  AgentDir* = "/var/lib/repro/agent"
  RecipientKeyPath* = AgentDir & "/recipient.key"
  RecipientPubPath* = AgentDir & "/recipient.pub"
  AgentStateDir* = AgentDir & "/state"
    ## The deploy agent's ``--state-dir`` on an add-on host; its sequence
    ## floor lives in ``deploy-agent/`` below it.
  AgentStateRecordsDir* = AgentStateDir & "/deploy-agent"
  AgentStateRecordSuffixes* = [".seq", ".last-tick.json", ".tick-history.jsonl"]
    ## The per-target files the deploy agent keeps there: the monotonic
    ## sequence floor (``agent.nim``), the last tick and the tick history.
  PreBootstrapSignersPath* = "/etc/repro/deploy-manifest-allowed-signers"
    ## The allowed-signers file a pre-bootstrap deploy agent reads.
  PreBootstrapTmpfilesPath* = "/etc/tmpfiles.d/repro-addon-bootstrap.conf"
    ## The tmpfiles fragment a pre-bootstrap stand-up installs so that
    ## ``/run/repro/secrets`` (a tmpfs, §5.3) exists at every boot.
  SecretsRunDir* = "/run/repro/secrets"
  PreBootstrapTmpfilesRules* = [
    @["d", "/run/repro", "0755", "root", "root"],
    @["d", "/run/repro/secrets", "0700", "root", "root"],
  ]
    ## The only rules the kept fragment may hold, in this order (an age
    ## field of ``-`` may follow each). Anything else -- another type, a
    ## wider mode, another owner, another path -- is a refusal: tmpfiles.d
    ## rules run as root at every boot, so a fragment is accepted by its
    ## exact content, never by the paths it names.
  RootOwner* = (uid: 0, gid: 0)

  UnitSearchDirs* = ["/etc/systemd/system", "/run/systemd/system",
                     "/run/systemd/transient", "/run/systemd/generator",
                     "/usr/local/lib/systemd/system", "/usr/lib/systemd/system",
                     "/lib/systemd/system"]

  ReadOnlyRootTypes* = ["squashfs", "iso9660", "erofs"]

# ---------------------------------------------------------------------------
# Canonical JSON: object keys sorted, no insignificant whitespace.
# ---------------------------------------------------------------------------

proc canonical*(n: JsonNode): string =
  case n.kind
  of JObject:
    var keys: seq[string]
    for k in n.keys: keys.add(k)
    keys.sort()
    result = "{"
    for i, k in keys:
      if i > 0: result.add(',')
      result.add(escapeJson(k))
      result.add(':')
      result.add(canonical(n[k]))
    result.add('}')
  of JArray:
    result = "["
    for i, e in n.elems:
      if i > 0: result.add(',')
      result.add(canonical(e))
    result.add(']')
  else:
    result = $n

# ---------------------------------------------------------------------------
# Facts. Each reader is pure over file contents where it can be, so it is
# unit-testable against captured files.
# ---------------------------------------------------------------------------

proc parseOsRelease*(text: string): OsRelease =
  ## os-release(5): ``KEY=value`` lines, values optionally quoted.
  result = initTable[string, string]()
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    let eq = line.find('=')
    if eq <= 0: continue
    var v = line[eq + 1 .. ^1]
    if v.len >= 2 and v[0] in {'"', '\''} and v[^1] == v[0]:
      v = v[1 ..< v.len - 1]
    result[line[0 ..< eq]] = v

proc readOsRelease*(): OsRelease =
  for p in ["/etc/os-release", "/usr/lib/os-release"]:
    if fileExists(p):
      return parseOsRelease(readFile(p))
  initTable[string, string]()

proc elfArchitecture*(header: string): string =
  ## The Debian architecture name of an ELF image from its first 52 bytes:
  ## class, ``e_machine`` and, for 32-bit ARM, the hard-float ABI flag.
  ## "" when the header is not one of the base matrix's.
  if header.len < 40 or header[0 .. 3] != "\x7fELF":
    return ""
  let cls = ord(header[4])
  let machine = ord(header[18]) or (ord(header[19]) shl 8)
  case machine
  of 62: (if cls == 2: "amd64" else: "")
  of 183: (if cls == 2: "arm64" else: "")
  of 40:
    if cls != 1: return ""
    let flags = ord(header[36]) or (ord(header[37]) shl 8) or
                (ord(header[38]) shl 16) or (ord(header[39]) shl 24)
    if (flags and 0x400) != 0: "armhf" else: "armel"
  else: ""

proc readHeader(path: string): string =
  var f: File
  if not open(f, path, fmRead):
    return ""
  defer: f.close()
  result = newString(52)
  let n = f.readBuffer(addr result[0], 52)
  result.setLen(max(n, 0))

proc userspaceArchitecture*(): string =
  ## Read from PID 1's image: the kernel's ``uname -m`` reports ``aarch64``
  ## for a 32-bit armhf userspace on a 64-bit Raspberry Pi kernel, and the
  ## add-on's binary must match the userspace, not the kernel.
  result = elfArchitecture(readHeader("/proc/1/exe"))
  if result.len == 0:
    result = elfArchitecture(readHeader("/proc/self/exe"))

proc firstLine(path: string): string =
  try:
    result = readFile(path).splitLines()[0].strip()
  except IOError, OSError, IndexDefect:
    result = ""

proc systemdMajor*(versionOutput: string): int =
  ## ``systemd 257 (257.8-1~deb13u2)`` -> 257; 0 when unparsable.
  let f = versionOutput.splitLines()[0].splitWhitespace()
  if f.len >= 2 and f[0] == "systemd":
    try: return parseInt(f[1]) except ValueError: discard
  0

proc fstabRootOptions*(text: string): string =
  ## The options field of the fstab entry for ``/``, "" if none.
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    let f = line.splitWhitespace()
    if f.len >= 4 and f[1] == "/":
      return f[3]
  ""

proc pathPresent(path: string): bool =
  var st: Stat
  lstat(path.cstring, st) == 0

proc unitDefinedAnywhere(name: string): string =
  for d in UnitSearchDirs:
    if pathPresent(d / name):
      return d / name
  ""

proc anchorText(path: string): string =
  if path.len == 0: "" else: readFile(path)

# ---------------------------------------------------------------------------
# Pre-bootstrap inputs versus foreign occupants (spec §6.1).
# ---------------------------------------------------------------------------

proc inodeKind(path: string): string =
  ## ``dir``, ``file``, ``symlink``, ``other`` or "" when absent. ``lstat``:
  ## a link is reported as one, never followed.
  var st: Stat
  if lstat(path.cstring, st) != 0:
    return ""
  if S_ISLNK(st.st_mode): "symlink"
  elif S_ISDIR(st.st_mode): "dir"
  elif S_ISREG(st.st_mode): "file"
  else: "other"

proc sortedEntries(dir: string): seq[string] =
  for kind, p in walkDir(dir, relative = true, checkDir = false):
    result.add(p)
  result.sort()

proc tmpfilesRules*(text: string): seq[seq[string]] =
  ## Every rule of a tmpfiles.d(5) fragment as its whitespace-separated
  ## fields, comments and blank lines skipped, a trailing ``-`` age field
  ## dropped (it is the default).
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    var f = line.splitWhitespace()
    if f.len == 6 and f[5] == "-": f.setLen(5)
    result.add(f)

proc tmpfilesFragmentRefusal*(text: string): string =
  ## "" when ``text`` is exactly the stand-up fragment of spec §6.1
  ## (``PreBootstrapTmpfilesRules``), else why it is refused.
  let rules = tmpfilesRules(text)
  if rules.len != PreBootstrapTmpfilesRules.len:
    return "holds " & $rules.len & " rule(s); the stand-up fragment is " &
           "exactly `d /run/repro 0755 root root -` and `d " &
           SecretsRunDir & " 0700 root root -`"
  for i, r in rules:
    if r != PreBootstrapTmpfilesRules[i]:
      return "rule `" & r.join(" ") & "` is not `" &
             PreBootstrapTmpfilesRules[i].join(" ") & "`"
  ""

proc inspectOccupancy*(hostRoot: string; deploySigners: seq[string];
                       deploySignersGiven: bool;
                       owner = RootOwner): OccupancyReport =
  ## Classify what exists at the add-on's own roots into the pre-bootstrap
  ## inputs bootstrap takes over and the foreign occupants it refuses,
  ## by the closed list of spec §6.1. Reads only; ``hostRoot`` ("" or "/"
  ## for the live host) is prepended to every path so the classification
  ## can be exercised against a fixture tree, and ``owner`` is who every
  ## accepted path must belong to (root on the live host; the test's own
  ## uid on a fixture).
  ##
  ## Shape is not enough: an input is accepted only with the ownership and
  ## mode that make it safe to take over -- every directory ``owner``'s and
  ## not group- or other-writable, every file ``owner``'s and not group- or
  ## other-writable, the recipient key exactly ``0400`` (a key that was
  ## ever wider is refused as compromised, never narrowed) and parseable,
  ## its ``.pub`` its own public half. Bootstrap re-runs this before it
  ## writes, so a refusal here is a refusal before any write.
  ##
  ## ``deploySigners`` are the ``--deploy-signers`` anchors when
  ## ``deploySignersGiven``; a kept signers file must then hold the same
  ## key set, so generation 0's anchors are a re-rendering of it.
  var inputs: PreBootstrapInputs
  var refused: seq[string]
  let prefix = if hostRoot.len == 0 or hostRoot == "/": "" else: hostRoot
  proc hp(p: string): string = prefix & p
  proc refuse(p, why: string) = refused.add(p & ": " & why)

  proc modeOf(p: string): int =
    var st: Stat
    if lstat(hp(p).cstring, st) != 0: -1 else: int(st.st_mode) and 0o7777

  # Ownership and the write bits, the same for every accepted path.
  proc ownedAndUnshared(p: string): bool =
    var st: Stat
    if lstat(hp(p).cstring, st) != 0:
      return false
    if int(st.st_uid) != owner.uid or int(st.st_gid) != owner.gid:
      refuse(p, "owned by " & $st.st_uid & ":" & $st.st_gid & ", not " &
             $owner.uid & ":" & $owner.gid)
      return false
    if (int(st.st_mode) and 0o022) != 0:
      refuse(p, "writable by group or others (mode " &
             toOct(int(st.st_mode) and 0o7777, 4) & ")")
      return false
    true

  # A directory on the list: accepted when it is a real directory, owned
  # and unshared, whose entries are all on its own allowed list
  # (``anyEntry``: the caller judges the entries itself). Returns true
  # when the caller may look inside it.
  proc acceptDir(p: string; allowed: openArray[string];
                 anyEntry = false): bool =
    case inodeKind(hp(p))
    of "": false
    of "dir":
      if not ownedAndUnshared(p):
        return false
      inputs.roots.add(p)
      if not anyEntry:
        for name in sortedEntries(hp(p)):
          if name notin allowed:
            refuse(p & "/" & name, "not a pre-bootstrap input (only " &
                   allowed.join(", ") & " may exist under " & p & ")")
      true
    of "symlink":
      refuse(p, "a symbolic link")
      false
    else:
      refuse(p, "not a directory")
      false

  # A directory on the list that must hold nothing: ``what`` says what an
  # entry in it would be.
  proc acceptEmptyDir(p, what: string) =
    if acceptDir(p, [], anyEntry = true):
      let es = sortedEntries(hp(p))
      if es.len > 0:
        refuse(p, "not empty (" & what & "): " & es.join(", "))

  proc acceptFile(p: string): bool =
    case inodeKind(hp(p))
    of "": false
    of "file": ownedAndUnshared(p)
    of "symlink":
      refuse(p, "a symbolic link")
      false
    else:
      refuse(p, "not a regular file")
      false

  proc keep(p: string; pinned: bool) =
    inputs.keptFiles.add(KeptFile(path: p, pinned: pinned,
      sha256: (if pinned: sha256OfFile(hp(p)) else: "")))

  # /repro: only the empty store root.
  if acceptDir(ReproRoot, ["store"]):
    acceptEmptyDir(StoreRoot, "a store in use")

  # /etc/repro: only the pre-bootstrap signers file.
  if acceptDir("/etc/repro", ["deploy-manifest-allowed-signers"]) and
      acceptFile(PreBootstrapSignersPath):
    var keys: seq[string]
    var err = ""
    try:
      keys = parseAnchorKeys(readFile(hp(PreBootstrapSignersPath)),
                             PreBootstrapSignersPath)
    except CatchableError as e:
      err = e.msg
    if err.len > 0:
      refuse(PreBootstrapSignersPath, "not a deploy-signer anchor file (" &
             err & ")")
    elif deploySignersGiven and keys != deploySigners:
      refuse(PreBootstrapSignersPath, "its " & $keys.len & " signer key(s) " &
             "are not the --deploy-signers anchors (" & $deploySigners.len &
             " key(s)); generation 0 can only re-render the same set")
    else:
      inputs.signersFile = PreBootstrapSignersPath
      inputs.signersKeys = keys
      keep(PreBootstrapSignersPath, pinned = true)

  # /var/lib/repro: an empty system state directory (no generation of an
  # earlier install) and the deploy agent's directory with its key and
  # sequence floor.
  if acceptDir("/var/lib/repro", ["system", "agent"]):
    acceptEmptyDir("/var/lib/repro/system",
                   "generations or state of an earlier install")
    if acceptDir(AgentDir, ["recipient.key", "recipient.pub", "state"]):
      # The key: exactly 0400 and usable. ``acceptFile`` already refused a
      # link, another owner and the write bits; a key readable by group or
      # others may have been read by them, so it is refused as compromised,
      # not narrowed to 0400 (that is why the check is here and not only
      # in the keygen, which bootstrap reaches after it has written).
      if acceptFile(RecipientKeyPath):
        let mode = modeOf(RecipientKeyPath)
        if mode != 0o400:
          refuse(RecipientKeyPath, "mode " & toOct(mode, 4) & ", not 0400: " &
                 "a recipient key readable by group or others is refused " &
                 "as compromised, never narrowed")
        else:
          var pubHex = ""
          var err = ""
          try:
            pubHex = peerAuth.publicKeyHex(peerAuth.derivePublicKey(
              peerAuth.loadPrivateKeyFile(hp(RecipientKeyPath))))
          except CatchableError as e:
            err = e.msg
          if err.len > 0:
            refuse(RecipientKeyPath, "not a usable recipient key (" & err & ")")
          else:
            inputs.recipientKey = RecipientKeyPath
            inputs.recipientPublicKey = pubHex
            keep(RecipientKeyPath, pinned = true)
      if acceptFile(RecipientPubPath):
        if inputs.recipientPublicKey.len == 0:
          refuse(RecipientPubPath, "present without a usable " &
                 RecipientKeyPath & " beside it")
        elif readFile(hp(RecipientPubPath)).strip() != inputs.recipientPublicKey:
          refuse(RecipientPubPath, "is not the public half of " &
                 RecipientKeyPath)
        else:
          keep(RecipientPubPath, pinned = true)
      if acceptDir(AgentStateDir, ["deploy-agent"]) and
          acceptDir(AgentStateRecordsDir, [], anyEntry = true):
        for name in sortedEntries(hp(AgentStateRecordsDir)):
          let p = AgentStateRecordsDir & "/" & name
          var known = false
          for suf in AgentStateRecordSuffixes:
            if name.endsWith(suf): known = true
          if not known:
            refuse(p, "not a deploy-agent record (" &
                   AgentStateRecordSuffixes.join(", ") & ")")
          elif acceptFile(p):
            keep(p, pinned = false)   # rewritten by the agent at every tick

  # /run/repro: only the empty materialised-secrets directory.
  if acceptDir("/run/repro", ["secrets"]):
    acceptEmptyDir(SecretsRunDir, "materialised secrets")

  # The tmpfiles fragment that recreates /run/repro/secrets at boot:
  # accepted only as exactly the stand-up's two rules.
  if acceptFile(PreBootstrapTmpfilesPath):
    let why = tmpfilesFragmentRefusal(readFile(hp(PreBootstrapTmpfilesPath)))
    if why.len > 0:
      refuse(PreBootstrapTmpfilesPath, why)
    else:
      inputs.tmpfilesFragment = PreBootstrapTmpfilesPath
      keep(PreBootstrapTmpfilesPath, pinned = true)

  # Any repro-* unit anywhere in the load path -- as a unit file, a
  # drop-in directory, or a link in a ``.wants`` / ``.requires``
  # directory: an earlier install's or a pre-bootstrap stand-up's agent
  # units, which bootstrap neither adopts nor overwrites.
  for d in UnitSearchDirs:
    if inodeKind(hp(d)) != "dir": continue
    for name in sortedEntries(hp(d)):
      if name.startsWith("repro-"):
        refuse(d & "/" & name, "a repro-* unit; the add-on's units must be " &
               "absent before bootstrap")
      elif (name.endsWith(".wants") or name.endsWith(".requires")) and
          inodeKind(hp(d & "/" & name)) == "dir":
        for link in sortedEntries(hp(d & "/" & name)):
          if link.startsWith("repro-"):
            refuse(d & "/" & name & "/" & link, "a repro-* unit link; the " &
                   "add-on's units must be absent before bootstrap")

  refused.sort()
  result = OccupancyReport(inputs: inputs, refused: refused)

proc renderPreBootstrap*(inputs: PreBootstrapInputs): string =
  ## One line naming what bootstrap will take over, for the check detail.
  var parts: seq[string]
  if inputs.roots.len > 0:
    parts.add($inputs.roots.len & " existing director" &
              (if inputs.roots.len == 1: "y" else: "ies") & " (" &
              inputs.roots.join(", ") & ")")
  if inputs.keptFiles.len > 0:
    var names: seq[string]
    for k in inputs.keptFiles:
      names.add(k.path & (if k.pinned: "" else: " (content unpinned)"))
    parts.add($inputs.keptFiles.len & " kept file(s) (" & names.join(", ") & ")")
  if parts.len == 0: "" else: parts.join("; ")

# ---------------------------------------------------------------------------
# The preflight.
# ---------------------------------------------------------------------------

proc baseMatrixNote*(id, versionId: string): string =
  ## The matrix entry's note for an ``os-release`` ``ID`` / ``VERSION_ID``
  ## pair ("supported", "release-upgrade source"), or "" when the pair is
  ## not in the matrix. Raspberry Pi OS reports ``ID=raspbian`` (with
  ## ``ID_LIKE=debian``) and is its own row.
  for b in SupportedBases:
    if b.id == id and b.versionId == versionId:
      return b.note
  ""

proc add(r: var PreflightReport; id: string; ok: bool; detail: string) =
  r.checks.add(PreflightCheck(id: id, verdict: (if ok: vPass else: vFail),
                              detail: detail))

proc runPreflight*(inp: PreflightInputs): PreflightReport =
  ## Inventory the host and compute the plan. Writes nothing.
  when mutated("preflight-writes"):
    # FALSIFYING MUTATION (see mutations.nim): a preflight that writes, and
    # swallows the error when it cannot -- so only observing the write, not
    # the preflight's exit status, can catch it.
    try:
      writeFile("/var/lib/repro-addon-preflight-was-here", "x")
    except IOError, OSError:
      discard
  let binary = if inp.binaryPath.len > 0: inp.binaryPath else: "/proc/self/exe"
  result.binarySha256 = sha256OfFile(binary)

  # Root: the add-on is installed by root, and only root can read the
  # facts below (PID 1's image, /var/lib).
  let isRoot = geteuid() == 0
  result.add("root-privilege", isRoot,
    if isRoot: "running as root" else: "the preflight must run as root")

  # Base distribution.
  let osr = readOsRelease()
  let id = osr.getOrDefault("ID")
  let versionId = osr.getOrDefault("VERSION_ID")
  let idLike = osr.getOrDefault("ID_LIKE")
  let baseNote = baseMatrixNote(id, versionId)
  result.add("distribution", baseNote.len > 0,
    if baseNote.len > 0: id & " " & versionId & " (" & baseNote & ")"
    else: "ID=" & id & " VERSION_ID=" & versionId &
          " is not in the add-on base matrix (" & SupportedBaseList & ")")

  # Architecture of the userspace.
  let arch = userspaceArchitecture()
  result.add("architecture", arch in SupportedArchitectures,
    if arch.len > 0: arch else: "unrecognised userspace architecture")

  # PID 1 must be systemd.
  let pid1 = firstLine("/proc/1/comm")
  let booted = dirExists("/run/systemd/system")
  var systemd = 0
  try:
    let v = runSystemctl(["--version"])
    if v.exitCode == 0: systemd = systemdMajor(v.output)
  except HostToolMissing:
    systemd = 0
  let isSystemd = pid1 == "systemd" and booted and systemd > 0
  result.add("init-system", isSystemd,
    if isSystemd: "systemd " & $systemd & " is PID 1"
    else: "PID 1 is '" & pid1 & "'" &
          (if booted: "" else: ", /run/systemd/system is absent") &
          "; the add-on needs systemd as PID 1")

  # Trust anchors: the deploy-manifest signers, and the binary cache with
  # the only publisher keys trusted for it. Parsed before the occupancy
  # pass, which compares a kept signers file against them.
  var signers, publishers: seq[string]
  var anchorsError = ""
  try:
    signers = parseAnchorKeys(anchorText(inp.deploySignersPath),
                              "--deploy-signers")
    publishers = parseAnchorKeys(anchorText(inp.cachePublishersPath),
                                 "--cache-publishers")
    discard renderCachesConf(inp.cacheUrl, publishers)
  except CatchableError as e:
    anchorsError = e.msg

  # What already exists at the add-on's own roots: pre-bootstrap inputs
  # bootstrap takes over, or foreign occupants (spec §6.1).
  let occupancy = inspectOccupancy("", signers, inp.deploySignersPath.len > 0)
  result.preBootstrap = occupancy.inputs
  var signersSource = ""
  if inp.deploySignersPath.len == 0 and anchorsError.len == 0 and
      occupancy.inputs.signersFile.len > 0:
    # No --deploy-signers: the host's own signers file is the anchor set,
    # re-rendered into generation 0's anchors.
    signers = occupancy.inputs.signersKeys
    signersSource = " (from " & occupancy.inputs.signersFile & ")"

  # The root filesystem and /repro.
  var fsType = ""
  var free = 0'u64
  try:
    let fs = statFs("/")
    fsType = fsTypeName(fs.magic)
    free = fs.availableBytes
  except OSError:
    fsType = "unknown"
  result.rootFsType = fsType
  let fstabRo = "ro" in fstabRootOptions(
    if fileExists("/etc/fstab"): readFile("/etc/fstab") else: "").split(',')
  let rootWritable = fsType notin ReadOnlyRootTypes and not fstabRo
  let reproExists = ReproRoot in occupancy.inputs.roots
  result.add("repro-root", rootWritable,
    if rootWritable and reproExists:
      "the existing " & ReproRoot & " (a pre-bootstrap input) is taken over " &
      "on the " & fsType & " root"
    elif rootWritable: "/repro can be created on the " & fsType & " root" &
                     (if fsType == "btrfs": " (as a subvolume)" else: "")
    else: "the root filesystem is read-only by design (" & fsType &
          (if fstabRo: ", fstab mounts / ro" else: "") &
          "); /repro cannot be created and there is no fallback")
  result.add("free-space", free >= MinimumFreeBytes,
    if free >= MinimumFreeBytes: "at least 512 MiB free on /"
    else: "less than 512 MiB free on /")

  # Foreign occupants of the add-on's own roots, as distinct from the
  # pre-bootstrap inputs bootstrap takes over.
  let takenOver = renderPreBootstrap(occupancy.inputs)
  result.add("foreign-occupants", occupancy.refused.len == 0,
    if occupancy.refused.len > 0:
      "refused: " & occupancy.refused.join("; ") &
      " (the add-on is installed, or something else owns these paths)"
    elif takenOver.len == 0: "none of " & AddonOwnedRoots.join(", ") & " exists"
    else: "pre-bootstrap inputs taken over: " & takenOver)

  result.add("trust-anchors", anchorsError.len == 0,
    if anchorsError.len > 0: anchorsError
    else: $signers.len & " deploy signer(s)" & signersSource &
          (if signers.len > 0: ": " & signers.join(", ") else: "") & "; " &
          (if inp.cacheUrl.len == 0: "no binary cache"
           else: "cache " & inp.cacheUrl & " trusting " & $publishers.len &
                 " publisher key(s): " & publishers.join(", ")))
  if anchorsError.len > 0:
    publishers = @[]

  # Generation 0 must find every one of its paths absent.
  let reproExe = reproExeFor(result.binarySha256)
  result.gen0Inputs = Gen0Inputs(reproExe: reproExe, deploySigners: signers,
    cacheUrl: (if anchorsError.len > 0: "" else: inp.cacheUrl),
    cachePublishers: publishers)
  result.gen0 = generation0Objects(result.gen0Inputs)
  var taken: seq[string]
  for o in result.gen0:
    if pathPresent(o.path):
      taken.add(o.path)
    if o.kind == ookUnit:
      let other = unitDefinedAnywhere(o.unit)
      if other.len > 0 and other notin taken:
        taken.add(other)
  result.add("generation-0-paths", taken.len == 0,
    if taken.len == 0: "every path generation 0 writes is absent"
    else: "already present: " & taken.join(", "))

  result.compatible = true
  for c in result.checks:
    if c.verdict == vFail: result.compatible = false

  # The plan.
  var names: seq[string]
  for o in result.gen0:
    if o.kind == ookEtcFile: names.add(contentFileName(o))
  let filesDir = filesPrefixPath(names)
  let gen0Text = renderOwnProfile(result.gen0, filesDir)
  var checksJson = newJArray()
  for c in result.checks:
    checksJson.add(%*{"id": c.id, "verdict": $c.verdict, "detail": c.detail})
  var objects = newJArray()
  for p in ownObjectPaths(result.gen0): objects.add(%p)
  # The kept files by path AND, for the content-pinned ones, by digest, so
  # a swap between the preflight and the bootstrap changes the digest the
  # operator acknowledged. An agent record is bound by path only: the
  # agent rewrites it at every tick.
  var keptJson = newJArray()
  for k in result.preBootstrap.keptFiles:
    keptJson.add(%*{"path": k.path, "sha256": k.sha256, "pinned": k.pinned})
  let plan = %*{
    "schema": PlanSchema,
    "compatible": result.compatible,
    "host": {
      "machineId": firstLine("/etc/machine-id"),
      "hostname": firstLine("/proc/sys/kernel/hostname"),
    },
    "base": {
      "id": id, "versionId": versionId, "idLike": idLike,
      "architecture": arch, "pid1": pid1, "systemd": systemd,
      "container": firstLine("/run/systemd/container"),
    },
    "rootFilesystem": {
      "type": fsType,
      "storeRoot": (if fsType == "btrfs": "btrfs-subvolume" else: "dir"),
    },
    "checks": checksJson,
    "bootstrap": {
      "version": ReprobuildVersion,
      "binarySha256": result.binarySha256,
      "reproExe": reproExe,
    },
    "anchors": {
      "deploySigners": %signers,
      "cacheUrl": inp.cacheUrl,
      "cachePublishers": %publishers,
    },
    "generation0": {
      "objects": objects,
      "profileSha256": sha256Hex(gen0Text),
    },
    "preBootstrap": {
      "roots": %result.preBootstrap.roots,
      "keptFiles": keptJson,
      "recipientPublicKey": result.preBootstrap.recipientPublicKey,
    },
  }
  result.planJson = canonical(plan)
  result.digest = sha256Hex(result.planJson)

proc renderPreflightHuman*(r: PreflightReport): string =
  for c in r.checks:
    result.add(alignLeft($c.verdict, 5) & alignLeft(c.id, 20) & c.detail & "\n")
  result.add("\ncompatible: " & $r.compatible & "\n")
  result.add("plan digest: " & r.digest & "\n")
