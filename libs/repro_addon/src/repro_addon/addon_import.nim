## ``repro system addon import --unit <name>``: describe a hand-configured
## service as a profile skeleton (ReproOS Add-On Mode §11.2 step 1).
##
## Adoption is staged: describe, plan against the live host, adopt,
## converge. This is the first stage. It reads the unit systemd loads, its
## drop-ins, its ``EnvironmentFile=`` files and the ``/etc`` files its
## command lines and environment files name, and the tmpfiles fragments
## that create its state, and prints a profile in canonical text whose
## resources reproduce exactly those bytes. Planned against the same host
## (``repro infra plan --profile``), every object it declares already
## exists with the declared bytes, so the plan is a list of silent
## adoptions (§4.3) and nothing else.
##
## It writes nothing on the host: every read is through the collision
## driver's observers (dpkg's database, ``systemctl show``) or a plain
## file read, and the skeleton goes to standard output.
##
## What it cannot express it says, in ``# FLAG:`` lines at the head of the
## skeleton, rather than guess:
##
## - a command that runs a distribution path (``/usr/bin/vaultwarden``,
##   naming the package that owns it) or an operator-installed binary
##   outside any package: a store package needs choosing;
## - an environment file that sets a variable whose name says it is a
##   secret (``*TOKEN*``, ``*PASSWORD*``, ``*SECRET*``, ``*KEY*``): it
##   should become a credential (§10.3);
## - a referenced ``/etc`` file a package owns, a directory, or a file
##   outside ``/etc``: not adopted;
## - a drop-in the add-on's drop-in class cannot own under its name, a
##   tmpfiles fragment not named ``repro-<name>.conf`` (likewise), and a
##   unit a package provides: not adopted;
## - the service's account (``User=``), which exists unmanaged: declare it
##   at convergence;
## - its state locations (``StateDirectory=``, ``WorkingDirectory=``,
##   ``ReadWritePaths=`` below a variable-state root): the operator chooses
##   ``keep`` or ``carry`` for each (§11.1); there is no default, so the
##   skeleton suggests and does not declare.
##
## The managed ``/etc`` prefix it declares for each adopted file is the
## file's own path, the narrowest there is (decision 22).

import std/[algorithm, os, sets, strutils, tables]

import repro_elevation
import repro_infra

import ./collision
import ./mutations

type
  ImportError* = object of CatchableError
    ## The unit cannot be described (not loaded, masked, transient, or
    ## generated). Nothing was written.

  ImportSkeleton* = object
    unit*: string
    profile*: SystemProfile
    flags*: seq[string]
    text*: string                ## the skeleton as printed

  ImportObserver* = object
    ## Where the import reads the host. ``root`` relocates every file read
    ## for tests over a fixture tree; the driver answers package ownership
    ## and unit provision.
    root*: string
    driver*: CollisionDriver

const
  ExecKeys = ["ExecStart", "ExecStartPre", "ExecStartPost", "ExecCondition",
              "ExecReload", "ExecStop", "ExecStopPost"]
  StateKeys = ["StateDirectory", "CacheDirectory", "LogsDirectory",
               "WorkingDirectory", "ReadWritePaths"]
  DistributionPathPrefixes = ["/usr/", "/bin/", "/sbin/", "/lib/", "/lib64/",
                              "/opt/"]
  SecretWords = ["TOKEN", "PASSWORD", "PASSWD", "SECRET", "KEY", "CREDENTIAL"]
  TmpfilesDir = "/etc/tmpfiles.d"
  TmpfilesPrefix = "repro-"
  AdoptedFloorWaiver* = "serviceFloor: adopted as the operator wrote it; " &
    "converged to the floor in a reviewed edit (spec §11.2 step 4)"

proc hostPath(o: ImportObserver; path: string): string =
  if o.root.len == 0 or o.root == "/": path else: o.root & path

proc readHostFile(o: ImportObserver; path: string): string =
  readFile(o.hostPath(path))

proc isRegularHostFile(o: ImportObserver; path: string): bool =
  let p = o.hostPath(path)
  fileExists(p) and not symlinkExists(p)

proc unitDirectives*(text: string): seq[(string, string, string)] =
  ## ``(section, key, value)`` for every directive of a unit file, with
  ## systemd's line continuation (a trailing backslash) joined and
  ## comments dropped
  ## (https://www.freedesktop.org/software/systemd/man/latest/systemd.syntax.html).
  var section = ""
  var pending = ""
  for raw in text.splitLines():
    var line = raw
    if pending.len > 0:
      line = pending & " " & line.strip()
      pending = ""
    let t = line.strip()
    if t.len == 0 or t[0] in {'#', ';'}: continue
    if t.endsWith("\\"):
      pending = t[0 ..< t.len - 1].strip(leading = false)
      continue
    if t.startsWith("[") and t.endsWith("]"):
      section = t[1 ..< t.len - 1]
      continue
    let eq = t.find('=')
    if eq <= 0: continue
    result.add((section, t[0 ..< eq].strip(), t[eq + 1 .. ^1].strip()))

proc commandTokens*(value: string): seq[string] =
  ## The words of an ``Exec*=`` line, with the executable's special
  ## prefixes (``@-:+!``) removed and quotes stripped. A word with an
  ## ``=`` (``--config=/etc/x``) also yields its right-hand side.
  var words: seq[string]
  var cur = ""
  var quote = '\0'
  for c in value:
    if quote != '\0':
      if c == quote: quote = '\0'
      else: cur.add(c)
    elif c in {'"', '\''}:
      quote = c
    elif c in Whitespace:
      if cur.len > 0: words.add(cur)
      cur = ""
    else:
      cur.add(c)
  if cur.len > 0: words.add(cur)
  for i, w in words:
    var w2 = w
    if i == 0:
      while w2.len > 0 and w2[0] in {'@', '-', ':', '+', '!'}:
        w2 = w2[1 .. ^1]
    result.add(w2)
    let eq = w2.find('=')
    if eq > 0 and eq < w2.high:
      result.add(w2[eq + 1 .. ^1])

proc envFileAssignments*(text: string): seq[(string, string)] =
  ## ``KEY=value`` lines of an environment file (``#`` comments skipped,
  ## one level of quotes removed).
  for raw in text.splitLines():
    let t = raw.strip()
    if t.len == 0 or t[0] in {'#', ';'}: continue
    let eq = t.find('=')
    if eq <= 0: continue
    var v = t[eq + 1 .. ^1].strip()
    if v.len >= 2 and v[0] == v[^1] and v[0] in {'"', '\''}:
      v = v[1 ..< v.high]
    result.add((t[0 ..< eq].strip(), v))

proc looksSecret*(key: string): bool =
  let k = key.toUpperAscii()
  for w in SecretWords:
    if w in k: return true
  false

proc narrowestPrefix*(path: string): string =
  ## The managed prefix an adopted ``/etc`` file needs: the file's own
  ## path, the narrowest prefix there is (decision 22). A file in a shared
  ## directory (``/etc/default/alertmanager``) must not bring the whole
  ## directory under the add-on; widening a prefix is a reviewed edit at
  ## convergence.
  path

proc ownerText(d: CollisionDriver; path: string): string =
  let o = d.packageOwner(path)
  if o.package.len > 0: "package " & o.package else: ""

proc statePathOf(key, value: string): seq[string] =
  ## The absolute state locations a state directive names.
  for w in value.splitWhitespace():
    var p = w
    while p.len > 0 and p[0] in {'-', '+'}: p = p[1 .. ^1]
    let colon = p.find(':')
    if colon > 0: p = p[0 ..< colon]
    if p.len == 0: continue
    if not p.startsWith("/"):
      case key
      of "StateDirectory": p = "/var/lib/" & p
      of "CacheDirectory": p = "/var/cache/" & p
      of "LogsDirectory": p = "/var/log/" & p
      else: continue
    result.add(p)

const SecretPlaceholder* = "<secret: not copied; move it to a credential>"

proc environmentAssignments*(value: string): seq[(string, string)] =
  ## The ``KEY=value`` assignments of one ``Environment=`` line (several
  ## per line, each optionally quoted;
  ## https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Environment=).
  for w in commandTokens(value):
    let eq = w.find('=')
    if eq > 0: result.add((w[0 ..< eq], w[eq + 1 .. ^1]))

proc secretKeysOfUnitText*(text: string): seq[string] =
  ## The secret-looking names an ``Environment=`` of ``text`` sets.
  for (section, key, value) in unitDirectives(text):
    if section == "Service" and key == "Environment":
      for (k, v) in environmentAssignments(value):
        if looksSecret(k) and k notin result: result.add(k)

proc redacted*(text: string; keys: seq[string]): string =
  ## ``text`` with the value of each secret assignment replaced by
  ## ``SecretPlaceholder`` (``KEY=value`` in an environment file or an
  ## ``Environment=`` line); for the commented placeholder the skeleton
  ## shows instead of the object.
  var lines: seq[string]
  for l in text.splitLines():
    var line = l
    for k in keys:
      let i = line.find(k & "=")
      if i >= 0 and (i == 0 or line[i - 1] in {' ', '"', '\'', '\t', '='}):
        var j = i + k.len + 1
        var quote = '\0'
        if i > 0 and line[i - 1] in {'"', '\''}:
          quote = line[i - 1]            # "KEY=value" quoted as a whole
        elif j < line.len and line[j] in {'"', '\''}:
          quote = line[j]                # KEY="value"
          inc j
        var e = j
        while e < line.len and (if quote != '\0': line[e] != quote
                                 else: line[e] notin Whitespace):
          inc e
        line = line[0 ..< j] & SecretPlaceholder & line[e .. ^1]
    lines.add(line)
  lines.join("\n")

proc commentedStanza(r: SystemResource): string =
  for l in renderStanza(r).join("\n").split('\n'):
    result.add("#   " & l & "\n")

proc importUnit*(o: ImportObserver; unit: string): ImportSkeleton =
  ## Describe ``unit`` (see the module comment). Raises ``ImportError``
  ## when the unit cannot be described at all.
  result.unit = unit
  let unitErr = systemdUnitNameError("--unit", unit)
  if unitErr.len > 0:
    raise newException(ImportError, unitErr)
  let prov = o.driver.unitProvision(unit)
  if prov.loadState != "loaded":
    raise newException(ImportError, unit & " is not a loaded unit (" &
      prov.loadState & ")")
  var flags: seq[string]
  var resources: seq[SystemResource]
  var prefixes: seq[string]
  var seenFiles = initHashSet[string]()
  var texts: seq[string]            # the unit's own text and its drop-ins
  var placeholders: seq[string]     # commented stanzas for secret holders
  proc holdsSecrets(path, text: string; envFile: bool): seq[string] =
    ## The secret-looking names ``text`` (at ``path``) sets, each flagged.
    if envFile:
      for (k, v) in envFileAssignments(text):
        if looksSecret(k) and k notin result: result.add(k)
    else:
      result = secretKeysOfUnitText(text)
    for k in result:
      flags.add("secret: " & path & " sets " & k & ", which looks like a " &
        "secret: its value is not copied; at convergence move it to a " &
        "credential (`secrets.secretFile` and the unit's `credentials`, " &
        "spec §10.3) and out of the file")
    when mutated("import-copies-env-secret"):
      result = @[]
  let fragment = prov.fragmentPath
  let etcUnit = "/etc/systemd/system/" & unit
  var unitDeclared = false
  if fragment == etcUnit:
    let content = o.readHostFile(fragment)
    texts.add(content)
    let secrets = holdsSecrets(fragment, content, envFile = false)
    # The add-on puts every unit it defines under the service floor by
    # default (spec §10.1), which would render bytes other than the
    # operator's and turn the adoption into a write. The skeleton waives
    # it, by name and with its reason, so adopting writes nothing; putting
    # the unit under the floor is convergence (step 4).
    let unitRes = SystemResource(kind: srkSystemdSystemUnit, suName: unit,
      suContent: content, suEnabled: prov.unitFileState == "enabled",
      suFloorExceptions: @[AdoptedFloorWaiver],
      address: "systemUnit:" & unit)
    if secrets.len > 0:
      # The unit holds a secret: it is not declared (its bytes would put
      # the secret in the profile); the placeholder shows its shape.
      var ph = unitRes
      ph.suContent = redacted(content, secrets)
      placeholders.add(commentedStanza(ph))
    else:
      resources.add(unitRes)
      unitDeclared = true
    flags.add("floor: " & unit & " waives the service floor so that " &
      "adopting it writes nothing; converge it to the floor (remove the " &
      "waiver, name only the exceptions it needs, spec §10.1)")
  else:
    var pkgDir = false
    for d in PackageUnitDirs:
      if fragment.startsWith(d): pkgDir = true
    if not pkgDir:
      raise newException(ImportError, unit & " is loaded from " &
        (if fragment.len == 0: "no file" else: fragment) & ", which is " &
        "neither /etc/systemd/system nor a package unit directory " &
        "(a transient, generated, local or aliased unit is not adopted)")
    texts.add(o.readHostFile(fragment))
    discard holdsSecrets(fragment, texts[^1], envFile = false)
    let owner = o.driver.ownerText(fragment)
    flags.add("unit: " & unit & " is " & fragment &
      (if owner.len > 0: " from " & owner else: "") & "; the skeleton " &
      "declares no unit for it. At convergence declare it with " &
      "`collision = \"dropIn\"` (your lines as a drop-in) or " &
      "`collision = \"replace\"` (spec §4.3)")
  for d in prov.dropInPaths:
    let text = o.readHostFile(d)
    texts.add(text)
    let secrets = holdsSecrets(d, text, envFile = false)
    let base = extractFilename(d)
    let dropInDir = "/etc/systemd/system/" & unit & ".d/"
    let named = base.startsWith("50-repro-") and base.endsWith(".conf") and
      d == dropInDir & base
    let name = if named: base["50-repro-".len ..< base.len - ".conf".len]
               else: ""
    if not unitDeclared and fragment != etcUnit and named and
        name.len > 0 and isSafeDropInName(name):
      # A drop-in, named as the add-on's drop-in class names its own, over
      # a distribution unit: adopted as a `systemd.systemDropIn`.
      let r = SystemResource(kind: srkSystemdSystemDropIn, diUnit: unit,
        diName: name, diContent: text,
        address: "systemDropIn:" & unit & "/" & name)
      if secrets.len > 0:
        var ph = r
        ph.diContent = redacted(text, secrets)
        placeholders.add(commentedStanza(ph))
      else:
        resources.add(r)
      continue
    flags.add("drop-in: " & d & " stays unmanaged: the add-on owns drop-ins " &
      "only as `50-repro-<name>.conf` over a distribution unit; fold its " &
      "lines into the unit at convergence")
  # Every directive systemd reads for the unit, its own file first.
  var directives: seq[(string, string, string)]
  for t in texts: directives.add(unitDirectives(t))
  var referenced: seq[string]     # /etc files, in first-mention order
  var envFiles: seq[string]
  var users: seq[string]
  var statePaths: seq[string]
  for (section, key, value) in directives:
    if section != "Service": continue
    if key == "EnvironmentFile":
      var p = value
      if p.startsWith("-"): p = p[1 .. ^1]
      if p notin envFiles: envFiles.add(p)
    elif key in ExecKeys:
      let toks = commandTokens(value)
      if toks.len == 0: continue
      for i, tok in toks:
        if not tok.startsWith("/"): continue
        if i > 0 and stateDirectoryError(tok).len == 0 and
            dirExists(o.hostPath(tok)) and tok notin statePaths:
          # An argument naming a directory in a variable-state location
          # (`--storage.path=/var/lib/alertmanager`).
          statePaths.add(tok)
        if tok.startsWith("/etc/"):
          if tok notin referenced: referenced.add(tok)
        elif i == 0:
          var dist = false
          for pfx in DistributionPathPrefixes:
            if tok.startsWith(pfx): dist = true
          let owner = o.driver.ownerText(tok)
          if tok.startsWith("/repro/store/"):
            discard
          elif owner.len > 0:
            flags.add("binary: " & key & " runs " & tok & " from " & owner &
              ", a distribution path: choose a store package for it")
          elif dist or tok.startsWith("/usr/local/"):
            flags.add("binary: " & key & " runs " & tok & ", which no " &
              "package owns (installed by hand): choose a store package " &
              "for it")
    elif key in ["User", "Group"]:
      if value notin users: users.add(value)
    elif key in StateKeys:
      for p in statePathOf(key, value):
        if p notin statePaths: statePaths.add(p)
  for e in envFiles:
    if not e.startsWith("/etc/"):
      flags.add("environment file: " & e & " is outside /etc: not adopted")
      continue
    if e notin referenced: referenced.insert(e, 0)
    if o.isRegularHostFile(e):
      for (k, v) in envFileAssignments(o.readHostFile(e)):
        for tok in commandTokens(v):
          if tok.startsWith("/etc/") and tok notin referenced:
            referenced.add(tok)
  for path in referenced:
    if path in seenFiles: continue
    seenFiles.incl(path)
    let canon = nonCanonicalPathError("referenced file", path)
    if canon.len > 0:
      flags.add("file: " & path & " is not a canonical path: not adopted")
      continue
    let hp = o.hostPath(path)
    if symlinkExists(hp):
      flags.add("file: " & path & " is a symbolic link: not adopted")
      continue
    if dirExists(hp):
      flags.add("file: " & path & " is a directory: declare the files " &
        "in it that the service reads")
      continue
    if not fileExists(hp):
      flags.add("file: " & path & " is named but does not exist")
      continue
    let owner = o.driver.ownerText(path)
    if owner.len > 0:
      flags.add("file: " & path & " belongs to " & owner & ": not adopted " &
        "(at convergence, `collision = \"divert\"` takes it over, spec §4.3)")
      continue
    let prefix = narrowestPrefix(path)
    let perr = managedPrefixError(prefix)
    if perr.len > 0:
      flags.add("file: " & path & " cannot be managed: " & perr)
      continue
    let content = o.readHostFile(path)
    let fileRes = SystemResource(kind: srkFsSystemFile, sfPath: path,
      sfContent: content, address: "systemFile:" & path)
    let secrets = if path in envFiles:
                    holdsSecrets(path, content, envFile = true)
                  else: @[]
    if secrets.len > 0:
      var ph = fileRes
      ph.sfContent = redacted(content, secrets)
      placeholders.add(commentedStanza(ph))
      continue
    resources.add(fileRes)
    if prefix notin prefixes: prefixes.add(prefix)
  # The tmpfiles fragments that create a state location.
  if statePaths.len > 0 and dirExists(o.hostPath(TmpfilesDir)):
    var names: seq[string]
    for kind, p in walkDir(o.hostPath(TmpfilesDir), relative = true):
      if kind == pcFile and p.endsWith(".conf"): names.add(p)
    names.sort()
    for n in names:
      let path = TmpfilesDir / n
      let content = o.readHostFile(path)
      var mentions = false
      for line in content.splitLines():
        let f = line.splitWhitespace()
        if f.len >= 2 and f[1] in statePaths: mentions = true
      if not mentions: continue
      let owner = o.driver.ownerText(path)
      if owner.len > 0:
        flags.add("tmpfiles: " & path & " belongs to " & owner &
          ": not adopted")
        continue
      if not n.startsWith(TmpfilesPrefix):
        # The add-on's tmpfiles class owns `repro-<name>.conf` only
        # (spec §4.1), so a fragment of another name cannot be adopted as
        # it is.
        flags.add("tmpfiles: " & path & " cannot be adopted under its " &
          "name (the add-on owns `" & TmpfilesPrefix & "<name>.conf`): at " &
          "convergence declare its lines as a `linux.tmpfilesRule` and " &
          "remove this file")
        continue
      resources.add(SystemResource(kind: srkLinuxTmpfilesRule,
        tmpfilesName: n, tmpfilesContent: content,
        address: "tmpfilesRule:" & n))
  for u in users:
    flags.add("account: " & u & " (User=/Group=) exists unmanaged: " &
      "declare it with `linux.sysusersEntry` at convergence")
  for p in statePaths:
    if stateDirectoryError(p).len == 0:
      flags.add("state: " & p & " holds the service's state: declare " &
        "`stateDirectories = [\"keep:" & p & "\"]` (on a disk a " &
        "conversion keeps) or `[\"carry:" & p & "\"]` (backed up and " &
        "restored) on the unit (spec §11.1)")
  if not unitDeclared and resources.len == 0:
    flags.add("nothing to adopt: the skeleton declares no resource")
  prefixes.sort()
  result.profile.resources = resources
  if prefixes.len > 0:
    result.profile.addOn = AddOnSettings(declared: true,
                                         managedEtcPrefixes: prefixes)
  result.flags = flags
  var head = "# Skeleton of " & unit & ", written by `repro system addon " &
    "import`.\n# It reproduces the objects as they are; nothing was " &
    "written on the host.\n# Plan it with `repro infra plan --profile " &
    "<this file>` and review every FLAG.\n"
  for f in flags:
    head.add("# FLAG: " & f & "\n")
  if placeholders.len > 0:
    head.add("#\n# Not declared, because each holds a secret (its value is " &
      "replaced here):\n")
    for ph in placeholders: head.add(ph)
  result.text = head & "\n" & renderProfileText(result.profile)
  # The skeleton must be a profile the parser accepts as printed.
  discard parseSystemProfile(result.text)
  when mutated("import-writes-skeleton"):
    # FALSIFYING MUTATION: the import keeps a copy of what it printed on
    # the host, which the describe stage must never do.
    writeFile(o.hostPath("/etc/repro-import-" & unit & ".profile"), result.text)
