## The base identity of an add-on generation, the base-coupled units of a
## plan, and the supported-base gate of every apply.
##
## A distribution release upgrade (Debian 12 -> 13, Ubuntu 24.04 -> 26.04)
## replaces the base underneath a running add-on. The add-on keeps running
## -- its binary is static and its closures carry their own ``/usr`` -- but
## what it was planned against has changed. Three things follow, and this
## module holds all three:
##
## - **The base identity** is observed at plan time and kept with the
##   generation (``generations/<id>/addon-base``): ``os-release``
##   (``ID``, ``VERSION_ID``, ``VERSION_CODENAME``, ``ID_LIKE``), the
##   userspace architecture, the running systemd's version, the dpkg
##   status of every package the add-on depends on or collides with (and
##   one digest over them), and the digest of every vendor unit a
##   ``replace`` unit or a drop-in sits on. The apt hook compares the
##   vendor units against the current generation's record
##   (``apt_hook.nim``), and the plan id covers the identity's digest, so
##   a plan pinned before an upgrade is stale after it.
## - **Base-coupled units** are units that run a distribution binary
##   (``ExecStartPre=/usr/sbin/nft``, a bare command name systemd resolves
##   in the base's ``/usr``, a ``/bin/sh -c`` wrapper) or that modify a
##   distribution unit (a drop-in, a ``replace``). An upgrade can change
##   them underneath the add-on, so every plan lists them in its
##   release-upgrade checklist. A unit bound to an apt closure runs its
##   ``/usr`` from the store: its ``/usr`` paths are not the base's.
## - **The supported-base gate**: an apply (and a plan) against a base
##   outside the matrix of the preflight (``preflight.SupportedBases``) is
##   refused with ``EAddOnUnsupportedBase`` before anything is observed or
##   written; the deploy agent reports it as ``aoUnsupportedBase``, an
##   operator action (exit 2), never a retry.
##
## The pure functions take file contents, so the unit tests run them over
## captured text; ``observeBaseIdentity`` reads the host.

import std/[algorithm, os, sets, strutils, tables]

import repro_dsl_stdlib/packages/apt_closure
import repro_infra/addon_diagnostics
import repro_infra/profile

import ./collision
import ./fingerprint
import ./host_exec
import ./ledger
import ./mutations
import ./preflight

type
  BasePackage* = object
    name*, version*, architecture*, status*: string

  VendorUnit* = object
    unit*: string        ## the distribution unit's name
    fragment*: string    ## its file under a package unit directory
    sha256*: string      ## "absent" when the file is gone

  CoupledUnit* = object
    unit*: string
    reason*: string

  BaseIdentity* = object
    id*, versionId*, versionCodename*, idLike*: string
    architecture*: string
    systemd*: string          ## ``systemctl --version`` first line
    packages*: seq[BasePackage]
    packagesSha256*: string   ## digest of the packages' status lines
    vendorUnits*: seq[VendorUnit]
    coupled*: seq[CoupledUnit]

const
  BaseIdentityHeader* = "# repro-addon-base v1"
  BaseIdentityFileName* = "addon-base"
    ## Under ``generations/<id>/``, beside the generation's ledger.
  DpkgStatusPath* = "/var/lib/dpkg/status"
  AddonBasePackages* = ["systemd", "dpkg", "apt", "coreutils", "dash",
                        "bsdutils"]
    ## What the add-on itself runs on every base: PID 1 and ``systemctl``,
    ## the package database the collision observer reads, apt (the hook),
    ## ``timeout`` and ``logger`` (the hook's wrapper), and ``/bin/sh``.
  ExecKeys = ["ExecStart", "ExecStartPre", "ExecStartPost", "ExecStop",
              "ExecStopPost", "ExecReload", "ExecCondition"]
  SystemdExecSearchPath = ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin",
                           "/usr/bin"]
    ## Where systemd resolves a bare command name (systemd.service(5),
    ## "Command lines": the fixed search path, not ``$PATH``).

# ---------------------------------------------------------------------------
# dpkg status.
# ---------------------------------------------------------------------------

proc parseDpkgStatus*(text: string): Table[string, BasePackage] =
  ## ``Package`` -> its status fields, from ``/var/lib/dpkg/status``
  ## (deb-control(5) stanzas). A multi-arch package keeps the first stanza
  ## per name, which is the native one on every base of the matrix.
  result = initTable[string, BasePackage]()
  var cur: BasePackage
  proc flush(r: var Table[string, BasePackage]; p: var BasePackage) =
    if p.name.len > 0 and p.name notin r: r[p.name] = p
    p = BasePackage()
  for raw in text.splitLines():
    if raw.strip().len == 0:
      flush(result, cur)
      continue
    if raw[0] in {' ', '\t'}: continue
    let c = raw.find(':')
    if c <= 0: continue
    let v = raw[c + 1 .. ^1].strip()
    case raw[0 ..< c]
    of "Package": cur.name = v
    of "Version": cur.version = v
    of "Architecture": cur.architecture = v
    of "Status": cur.status = v
    else: discard
  flush(result, cur)

proc packagesDigest*(pkgs: seq[BasePackage]): string =
  var lines: seq[string]
  for p in pkgs:
    lines.add(p.name & "\t" & p.version & "\t" & p.architecture & "\t" &
              p.status)
  sha256Hex(lines.join("\n") & "\n")

# ---------------------------------------------------------------------------
# Base-coupled units.
# ---------------------------------------------------------------------------

proc execPrograms*(unitContent: string): seq[string] =
  ## The program of every ``Exec*=`` command line of a unit, as written
  ## (systemd.service(5) "Command lines": the special prefixes ``@ - : + !``
  ## are dropped; several commands of one ``ExecStartPre=`` are not split,
  ## each assignment carries one).
  for line in joinUnitContinuations(unitContent):
    let l = line.strip()
    if l.len == 0 or l[0] in {'#', ';'}: continue
    let eq = l.find('=')
    if eq <= 0: continue
    if l[0 ..< eq].strip() notin ExecKeys: continue
    var v = l[eq + 1 .. ^1].strip()
    var i = 0
    while i < v.len and v[i] in {'@', '-', ':', '+', '!'}: inc i
    v = v[i .. ^1].strip()
    if v.len == 0: continue
    result.add(v.splitWhitespace()[0])

proc isUsrPath(p: string): bool =
  ## A path a closure's ``BindReadOnlyPaths=<closure>/usr:/usr`` serves:
  ## under ``/usr``, or under the merged-``/usr`` links ``/bin``, ``/sbin``
  ## and ``/lib*`` that resolve into it.
  for pfx in ["/usr/", "/bin/", "/sbin/", "/lib/", "/lib64/", "/lib32/"]:
    if p.startsWith(pfx): return true
  false

proc unitCouplings*(r: SystemResource): seq[CoupledUnit] =
  ## Why ``r`` depends on the base, one entry per reason; empty when it
  ## runs only from the store.
  case r.kind
  of srkSystemdSystemUnit:
    if r.suCollision == "dropIn":
      result.add(CoupledUnit(unit: r.suName, reason: "a drop-in of the " &
        "distribution's " & r.suName))
      return
    if r.suCollision == "replace":
      result.add(CoupledUnit(unit: r.suName, reason: "replaces the " &
        "distribution's " & r.suName & "; its vendor unit may change"))
    let closure = r.suAptClosureLock.len > 0
    var seen = initHashSet[string]()
    for prog in execPrograms(r.suContent):
      if prog in seen: continue
      seen.incl(prog)
      if prog.startsWith(AddOnSystemStoreRoot & "/"): continue
      if not prog.startsWith("/"):
        if closure: continue    # resolved in the closure's /usr
        result.add(CoupledUnit(unit: r.suName, reason: "runs `" & prog &
          "` from the base's " & SystemdExecSearchPath.join(":")))
      elif closure and isUsrPath(prog):
        continue
      else:
        result.add(CoupledUnit(unit: r.suName, reason: "runs " & prog &
          " from the base"))
  of srkSystemdSystemDropIn:
    result.add(CoupledUnit(unit: r.diUnit, reason: "a drop-in (" &
      r.diName & ") of the distribution's " & r.diUnit))
  else: discard

proc baseCoupledUnits*(resources: openArray[SystemResource]): seq[CoupledUnit] =
  ## Every coupling of every unit, in profile order.
  when mutated("base-coupling-unflagged"):
    # FALSIFYING MUTATION: no unit is ever flagged.
    return @[]
  for r in resources:
    result.add(unitCouplings(r))

# ---------------------------------------------------------------------------
# Rendering.
# ---------------------------------------------------------------------------

proc renderBaseIdentity*(b: BaseIdentity): string =
  ## Canonical text: one ``key<TAB>value`` per line, lists sorted.
  result = BaseIdentityHeader & "\n"
  result.add("id\t" & b.id & "\n")
  result.add("version-id\t" & b.versionId & "\n")
  result.add("version-codename\t" & b.versionCodename & "\n")
  result.add("id-like\t" & b.idLike & "\n")
  result.add("architecture\t" & b.architecture & "\n")
  result.add("systemd\t" & b.systemd & "\n")
  result.add("packages-sha256\t" & b.packagesSha256 & "\n")
  for p in b.packages:
    result.add("package\t" & p.name & "\t" & p.version & "\t" &
               p.architecture & "\t" & p.status & "\n")
  for v in b.vendorUnits:
    result.add("vendor-unit\t" & v.unit & "\t" & v.fragment & "\t" &
               v.sha256 & "\n")
  for c in b.coupled:
    result.add("coupled\t" & c.unit & "\t" & c.reason & "\n")

proc parseBaseIdentity*(text: string): BaseIdentity =
  ## Inverse of ``renderBaseIdentity``. Raises ``ValueError`` on anything
  ## else.
  let lines = text.splitLines()
  if lines.len == 0 or lines[0] != BaseIdentityHeader:
    raise newException(ValueError, "not a base identity record")
  for l in lines[1 .. ^1]:
    if l.len == 0: continue
    let f = l.split('\t')
    case f[0]
    of "id": result.id = f[1]
    of "version-id": result.versionId = f[1]
    of "version-codename": result.versionCodename = f[1]
    of "id-like": result.idLike = f[1]
    of "architecture": result.architecture = f[1]
    of "systemd": result.systemd = f[1 .. ^1].join("\t")
    of "packages-sha256": result.packagesSha256 = f[1]
    of "package":
      if f.len != 5: raise newException(ValueError, "bad package line: " & l)
      result.packages.add(BasePackage(name: f[1], version: f[2],
        architecture: f[3], status: f[4]))
    of "vendor-unit":
      if f.len != 4: raise newException(ValueError, "bad vendor-unit line: " & l)
      result.vendorUnits.add(VendorUnit(unit: f[1], fragment: f[2],
                                        sha256: f[3]))
    of "coupled":
      if f.len < 3: raise newException(ValueError, "bad coupled line: " & l)
      result.coupled.add(CoupledUnit(unit: f[1], reason: f[2 .. ^1].join("\t")))
    else: raise newException(ValueError, "unknown base identity key: " & f[0])

proc baseIdentityDigest*(b: BaseIdentity): string =
  sha256Hex(renderBaseIdentity(b))

proc describeBase*(b: BaseIdentity): string =
  ## ``debian 13 (trixie) amd64, systemd 257``.
  result = b.id & " " & b.versionId
  if b.versionCodename.len > 0: result.add(" (" & b.versionCodename & ")")
  if b.architecture.len > 0: result.add(" " & b.architecture)
  let sd = b.systemd.splitWhitespace()
  if sd.len >= 2: result.add(", systemd " & sd[1])

proc baseIdentityChanges*(before, after: BaseIdentity): seq[string] =
  ## What changed between two identities, one line each ("" before means
  ## no earlier record).
  if before.id.len == 0: return
  if before.id != after.id or before.versionId != after.versionId:
    result.add("distribution: " & before.id & " " & before.versionId &
               " -> " & after.id & " " & after.versionId)
  if before.systemd != after.systemd:
    result.add("systemd: " & before.systemd & " -> " & after.systemd)
  var was = initTable[string, string]()
  for p in before.packages: was[p.name] = p.version
  for p in after.packages:
    if p.name in was and was[p.name] != p.version:
      result.add("package " & p.name & ": " & was[p.name] & " -> " & p.version)
    elif p.name notin was:
      result.add("package " & p.name & ": now considered (" & p.version & ")")
  var vb = initTable[string, string]()
  for v in before.vendorUnits: vb[v.unit] = v.sha256
  for v in after.vendorUnits:
    if v.unit in vb and vb[v.unit] != v.sha256:
      result.add("vendor unit " & v.unit & " changed (" & v.fragment & ")")

# ---------------------------------------------------------------------------
# The supported-base gate.
# ---------------------------------------------------------------------------

proc matrixRefusal*(b: BaseIdentity): string =
  ## "" when the base is in the supported matrix (spec §6.1), else why not.
  when mutated("base-matrix-unchecked"):
    # FALSIFYING MUTATION: every base is accepted.
    return ""
  if baseMatrixNote(b.id, b.versionId).len == 0:
    return "the base is ID=" & b.id & " VERSION_ID=" & b.versionId &
      ", which is not in the add-on's supported matrix (" &
      SupportedBaseList & ")"
  if b.architecture notin SupportedArchitectures:
    return "the userspace architecture '" & b.architecture &
      "' is not one of " & SupportedArchitectures.join(", ")
  ""

proc checkSupportedBase*(b: BaseIdentity) =
  ## Raise ``EAddOnUnsupportedBase`` (spec §7.9) for a base outside the
  ## matrix. Called before anything is observed or written.
  let why = matrixRefusal(b)
  if why.len > 0:
    raise newAddOnUnsupportedBase(describeBase(b), why & "; nothing was " &
      "planned or changed. Uninstall the add-on, or move the host to a " &
      "supported base")

# ---------------------------------------------------------------------------
# Observation.
# ---------------------------------------------------------------------------

proc vendorUnitFragment*(unit: string): string =
  ## The distribution's own file for ``unit``, or "" when no package unit
  ## directory carries one.
  for d in PackageUnitDirs:
    if fileExists(d & unit): return d & unit
  ""

proc vendorUnitDigest*(fragment: string): string =
  if fragment.len == 0 or not fileExists(fragment): "absent"
  else: sha256OfFile(fragment)

proc packageOfObservation*(observation: string): string =
  ## The package an ownership observation names (``package:``,
  ## ``conffile:``, ``ucf:``, ``diversion:``), or "".
  for pfx in ["package:", "conffile:", "ucf:", "diversion:"]:
    if observation.startsWith(pfx): return observation[pfx.len .. ^1]
  ""

proc vendorUnitsOf*(l: Ledger): seq[string] =
  ## The distribution units a generation's ledger sits on: a ``replace``d
  ## unit's name and the unit every drop-in modifies, sorted.
  var s = initHashSet[string]()
  for e in l.entries:
    if e.resource.len == 0: continue
    if e.class == lcUnit and e.collision == "replace": s.incl(e.unit)
    elif e.class == lcDropIn and e.unit.len > 0: s.incl(e.unit)
  for u in s: result.add(u)
  result.sort()

const
  OwnedPathClasses = {lcEtcFile, lcUnit, lcDropIn, lcInstallLink}
    ## Ledger classes whose path is a file a package could ship. The
    ## directories the add-on created are left out: dpkg shares
    ## directories between packages, so a package listing one is not a
    ## collision.

proc newOwnerFindings*(l: Ledger; driver: CollisionDriver): seq[string] =
  ## Every ledger path a package owns now that its plan-time observation
  ## did not name.
  for e in l.entries:
    if e.class notin OwnedPathClasses: continue
    var o: PackageOwnership
    try: o = driver.packageOwner(e.path)
    except CatchableError as ex:
      result.add("cannot read package ownership of " & e.path & ": " & ex.msg)
      continue
    if o.package.len == 0: continue
    if packageOfObservation(e.observation) == o.package: continue
    result.add("package " & o.package & " now owns ledger path " & e.path &
      (if o.conffile: " (conffile)" else: "") &
      (if e.resource.len > 0: " (" & e.resource & ")" else: "") &
      "; the add-on's object there is reported as drift by the next plan")

proc mergedUsrAliases(p: string): seq[string] =
  ## ``p`` and its merged-``/usr`` spelling: dpkg records a file under the
  ## name the package shipped it as, which is ``/bin/sh`` on one base and
  ## ``/usr/bin/sh`` on another.
  result = @[p]
  for (a, b) in [("/bin/", "/usr/bin/"), ("/sbin/", "/usr/sbin/"),
                 ("/lib/", "/usr/lib/")]:
    if p.startsWith(a): result.add(b & p[a.len .. ^1])
    elif p.startsWith(b): result.add(a & p[b.len .. ^1])

proc observeBaseIdentity*(ledger: Ledger;
                          resources: openArray[SystemResource];
                          driver: CollisionDriver): BaseIdentity =
  ## Read the host's base identity for a plan over ``resources`` against
  ## ``ledger`` (the generation the plan starts from). Read-only.
  let osr = readOsRelease()
  result.id = osr.getOrDefault("ID")
  result.versionId = osr.getOrDefault("VERSION_ID")
  result.versionCodename = osr.getOrDefault("VERSION_CODENAME")
  result.idLike = osr.getOrDefault("ID_LIKE")
  result.architecture = userspaceArchitecture()
  try:
    let r = runSystemctl(["--version"])
    if r.exitCode == 0 and r.output.len > 0:
      result.systemd = r.output.splitLines()[0].strip()
  except CatchableError:
    discard
  result.coupled = baseCoupledUnits(resources)
  # The packages: the add-on's own, every package a ledger observation
  # names, the owners of the vendor units and of every base binary a
  # coupled unit runs.
  var names = initHashSet[string]()
  for n in AddonBasePackages: names.incl(n)
  for e in ledger.entries:
    let p = packageOfObservation(e.observation)
    if p.len > 0: names.incl(p)
  var units = vendorUnitsOf(ledger)
  for r in resources:
    if r.kind == srkSystemdSystemUnit and r.suCollision in ["replace", "dropIn"]:
      if r.suName notin units: units.add(r.suName)
    elif r.kind == srkSystemdSystemDropIn:
      if r.diUnit notin units: units.add(r.diUnit)
  units.sort()
  for u in units:
    let frag = vendorUnitFragment(u)
    result.vendorUnits.add(VendorUnit(unit: u, fragment: frag,
                                      sha256: vendorUnitDigest(frag)))
    if frag.len > 0:
      let p = driver.packageOwner(frag).package
      if p.len > 0: names.incl(p)
  for r in resources:
    if r.kind != srkSystemdSystemUnit or r.suAptClosureLock.len > 0: continue
    for prog in execPrograms(r.suContent):
      var cands: seq[string]
      if prog.startsWith("/"): cands = mergedUsrAliases(prog)
      else:
        for d in SystemdExecSearchPath: cands.add(mergedUsrAliases(d & "/" & prog))
      for c in cands:
        let p = driver.packageOwner(c).package
        if p.len > 0:
          names.incl(p)
          break
  let status =
    try: parseDpkgStatus(readFile(DpkgStatusPath))
    except IOError, OSError: initTable[string, BasePackage]()
  var sorted: seq[string]
  for n in names: sorted.add(n)
  sorted.sort()
  for n in sorted:
    if n in status: result.packages.add(status[n])
    else: result.packages.add(BasePackage(name: n, status: "not-installed"))
  result.packagesSha256 = packagesDigest(result.packages)

proc readGenerationBase*(generationDir: string): BaseIdentity =
  ## The base identity a generation recorded; an empty identity when it has
  ## none (a generation written before this record existed) or it is
  ## unreadable.
  try:
    parseBaseIdentity(readFile(generationDir / BaseIdentityFileName))
  except CatchableError:
    BaseIdentity()

proc renderReleaseUpgradeChecklist*(b: BaseIdentity): string =
  ## The plan's release-upgrade checklist (spec §7.9): every base-coupled
  ## unit, with why.
  if b.coupled.len == 0:
    return "release-upgrade checklist: no base-coupled units\n"
  result = "release-upgrade checklist (base-coupled units; re-check them " &
    "after a distribution upgrade):\n"
  for c in b.coupled:
    result.add("  base-coupled\t" & c.unit & "\t" & c.reason & "\n")
