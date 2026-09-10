## The ``.msi`` producer (WiX Toolset v3).
##
## §6's table: ``dist.msi  # dep: wix3 -> <Name>-<ver>-<arch>.msi
## (WiX; service + PATH)``.
##
## ## Why this producer exists at M0 rather than at M2
##
## The M0 gate was moved to require an MSI alongside the ``.deb`` on the
## grounds that a packaging abstraction's real risk is whether it
## survives contact with a *structurally different* second format.
## rpm-vs-deb would not have tested it: both unpack a payload archive
## rooted at ``/``, both ship systemd units as files, both carry POSIX
## modes. MSI disagrees with deb on every one of those:
##
## | | deb | msi |
## |---|---|---|
## | install model | unpack a payload rooted at ``/`` | execute a relational database of Components against a Directory table |
## | prefix | fixed at build time | chosen at install time (``ProgramFiles64Folder``) |
## | services | ship a unit FILE, enable it from a shell script | write rows to the SCM through ``ServiceInstall`` |
## | file modes | 0755/0644, and dpkg REJECTS a wrong one | do not exist |
## | file identity | a path | a GUID-keyed Component whose key path is a file |
##
## Three things in the layer exist *because* of that column and would
## not have been discovered from deb and rpm alone:
##
## 1. ``installRelPath`` is prefix-relative, never absolute. MSI has no
##    build-time absolute path to be relative to.
## 2. ``roleDefaultSubdir`` returns the BIN directory for
##    ``crRuntimeLibrary`` on Windows, and there is no RPATH step. §5's
##    Windows arm is "PATH-adjacent DLL placement", and it is a
##    different mechanism for the same requirement rather than a
##    degraded version of the Unix one.
## 3. The mode-application step is POSIX-only, and the Windows staging
##    path uses the engine's own ``fs.copyFile`` builtin with no tool
##    dependency at all — see ``packages/coreutils_install.nim``.
##
## ## What is deliberately not here
##
## Per-user services (``ssUser``). The Windows SCM has none; see
## ``services.MsiServiceRow``. They are reported, not silently dropped.

import std/[strutils, tables]

import repro_project_dsl

import ../types
import ../runtime_contract
import ../services
import ../producer
import ../../fs as dslfs
import ../../packages/wix3_tools as wix_module

{.experimental: "callOperator".}

const
  candleTool = wix_module.wix_candle
  lightTool = wix_module.wix_light

const
  CandleSelector* = "wix-candle"
  LightSelector* = "wix-light"

proc msiArtifactName*(dist: Distribution): string =
  dist.name & "-" & dist.fullVersion & "-" & dist.msiArchitecture & ".msi"

proc xmlEscape(value: string): string =
  for ch in value:
    case ch
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&apos;")
    else: result.add(ch)

proc windowsPath(value: string): string =
  value.replace("/", "\\")

proc msiProductVersion*(dist: Distribution): string =
  ## MSI's ``ProductVersion`` is ``major.minor.build[.revision]`` with
  ## major/minor <= 255 and build <= 65535, and — the part that bites —
  ## **Windows Installer ignores the fourth field when comparing
  ## versions**. A packaging revision therefore cannot live there: two
  ## builds differing only in ``release`` would be indistinguishable to
  ## the upgrade logic. So ``release`` is dropped from the product
  ## version rather than appended, and the full version keeps living in
  ## the artifact's file name where nothing reinterprets it.
  var parts = dist.version.split('.')
  while parts.len < 3: parts.add("0")
  if parts.len > 3: parts = parts[0 ..< 3]
  parts.join(".")

type
  DirNode = ref object
    id: string
    name: string
    children: OrderedTable[string, DirNode]

proc dirIdFor(path: string): string =
  if path.len == 0: "INSTALLFOLDER"
  else: msiIdentifier("dir_" & path)

proc ensureDirNode(root: DirNode; relDir: string): DirNode =
  result = root
  if relDir.len == 0: return
  var acc = ""
  for part in relDir.split('/'):
    if part.len == 0: continue
    acc = if acc.len == 0: part else: acc & "/" & part
    if part notin result.children:
      result.children[part] = DirNode(id: dirIdFor(acc), name: part)
    result = result.children[part]

proc renderDirTree(node: DirNode; indent: int;
                   componentsByDir: Table[string, seq[string]]): string =
  let pad = " ".repeat(indent)
  for _, child in node.children:
    result.add(pad & "<Directory Id=\"" & child.id & "\" Name=\"" &
      xmlEscape(child.name) & "\">\n")
    if child.id in componentsByDir:
      for body in componentsByDir[child.id]:
        result.add(body)
    result.add(renderDirTree(child, indent + 2, componentsByDir))
    result.add(pad & "</Directory>\n")

proc dirOfRel(path: string): string =
  let cut = path.rfind('/')
  if cut < 0: "" else: path[0 ..< cut]

proc needsUtilExtension*(dist: Distribution): bool =
  ## Whether the authoring requires ``WixUtilExtension``.
  ##
  ## Asked as a question about the DISTRIBUTION rather than decided
  ## while rendering, because the answer has to be known in two places
  ## that are not the renderer: candle and light both need ``-ext`` on
  ## their own command lines, and a mismatch between the xmlns the .wxs
  ## declares and the extensions the tools load is a link-time failure
  ## about an unresolved custom action.
  for row in msiServiceRows(dist):
    if row.restartOnFailure: return true
  false

proc wxsText*(dist: Distribution; tree: StagedTree): string =
  ## Render the WiX v3 authoring for the staged tree.
  if dist.metadata.upgradeCode.len == 0:
    raise newException(ValueError,
      "distribution '" & dist.name & "': the MSI producer requires " &
      "metadata.upgradeCode — a GUID that is CONSTANT across every " &
      "version of this product and unique to it. It is what makes two " &
      "releases an upgrade rather than two side-by-side installs, so " &
      "the layer will not invent one: generate a GUID once and paste " &
      "it into the recipe.")

  let manufacturer =
    if dist.metadata.vendor.len > 0: dist.metadata.vendor
    elif dist.metadata.maintainer.len > 0: dist.metadata.maintainer
    else: dist.name
  let svcRows = msiServiceRows(dist)
  # ``InstallerVersion`` stays at the 2.0 floor even for a service with
  # a recovery policy.
  #
  # The first draft raised it to 500 on the assumption that failure
  # actions were the MSI 5.0 ``MsiServiceConfig`` table. candle rejected
  # that authoring outright (CNDL0044), which is how the assumption was
  # found to be wrong: service RECOVERY is
  # ``ChangeServiceConfig2(SERVICE_CONFIG_FAILURE_ACTIONS)``, a Win32
  # call Windows Installer never exposed as a table at all, and WiX
  # implements it as a custom action in WixUtilExtension. A custom
  # action imposes no InstallerVersion floor, so raising it would have
  # refused to install on older Windows for a requirement that does not
  # exist.
  let installerVersion = "200"
  let needsUtil = needsUtilExtension(dist)

  # Group components by the directory they live in, then render the
  # directory tree once. Building the tree from the STAGED FILES rather
  # than from the components means the §5 wrapper (which is a staged
  # file with no component of its own) is included by construction.
  var root = DirNode(id: "INSTALLFOLDER", name: dist.name)
  var componentsByDir = initTable[string, seq[string]]()
  var componentRefs: seq[string] = @[]
  let binDirRel = roleDefaultSubdir(dist, crExecutable)

  var index = 0
  for f in tree.files:
    inc index
    let relDir = dirOfRel(f.rootRelPath)
    discard ensureDirNode(root, relDir)
    let dirId = dirIdFor(relDir)
    let baseId = msiIdentifier($index & "_" & f.rootRelPath)
    let cmpId = "cmp_" & baseId
    let filId = "fil_" & baseId
    var body = ""
    # ``Guid="*"`` asks WiX to derive a stable GUID from the component's
    # key path and target directory. Deriving it is not a convenience:
    # a hand-written GUID that changes between builds turns every
    # upgrade into a reinstall of a different component, and a random
    # one is worse still. Deriving from the install location is exactly
    # the identity rule the Windows Installer component rules ask for.
    body.add("      <Component Id=\"" & cmpId & "\" Guid=\"*\">\n")
    body.add("        <File Id=\"" & filId & "\" KeyPath=\"yes\" Source=\"" &
      xmlEscape(windowsPath(tree.root & "/" & f.rootRelPath)) & "\" />\n")

    for row in svcRows:
      if row.exeRelPath != f.rootRelPath:
        continue
      body.add("        <ServiceInstall Id=\"" & row.id &
        "\" Type=\"ownProcess\" Vital=\"yes\" Name=\"" &
        xmlEscape(row.name) & "\" DisplayName=\"" &
        xmlEscape(row.displayName) & "\"")
      if row.description.len > 0:
        body.add(" Description=\"" & xmlEscape(row.description) & "\"")
      body.add(" Start=\"" & (if row.startAtBoot: "auto" else: "demand") &
        "\" Account=\"LocalSystem\" ErrorControl=\"normal\"")
      if row.args.len > 0:
        body.add(" Arguments=\"" & xmlEscape(row.args.join(" ")) & "\"")
      if row.restartOnFailure:
        body.add(">\n")
        # ``util:ServiceConfig``, NOT the core ``ServiceConfig``.
        #
        # This is not interchangeable and candle says so: the core
        # element is the MSI 5.0 ``MsiServiceConfig`` table, which
        # carries DelayedAutoStart / PreShutdownDelay / ServiceSid and
        # has no failure-action attributes at all. Service RECOVERY is
        # ``ChangeServiceConfig2(SERVICE_CONFIG_FAILURE_ACTIONS)``, which
        # Windows Installer never exposed as a table, so WiX implements
        # it as a custom action in WixUtilExtension. Using the core
        # element for a restart policy fails to compile — which is how
        # this was found — and, had it compiled, would have produced a
        # service with no recovery configured at all.
        body.add("          <util:ServiceConfig " &
          "FirstFailureActionType=\"restart\" " &
          "SecondFailureActionType=\"restart\" " &
          "ThirdFailureActionType=\"restart\" " &
          "ResetPeriodInDays=\"1\" " &
          "RestartServiceDelayInSeconds=\"10\" />\n")
        body.add("        </ServiceInstall>\n")
      else:
        body.add(" />\n")
      # ``Start="install"`` ONLY when the distribution asked for the
      # service to come up on its own. The mapping matters: a
      # ``ServiceControl`` that starts a demand-start service turns the
      # install into a synchronous wait on the SCM, and if the service
      # does not report SERVICE_RUNNING the installer ROLLS THE WHOLE
      # INSTALL BACK. Starting something the recipe said not to start at
      # boot would be wrong on its own terms; that it also converts a
      # non-service executable from "registered but idle" into "the
      # package will not install" is what makes it worth spelling out.
      body.add("        <ServiceControl Id=\"" & row.id &
        "_ctl\" Name=\"" & xmlEscape(row.name) & "\"")
      if row.startAtBoot:
        body.add(" Start=\"install\"")
      body.add(" Stop=\"both\" Remove=\"uninstall\" Wait=\"yes\" />\n")
      if row.environment.len > 0:
        # The SCM has no per-service environment block of its own; the
        # documented mechanism is a REG_MULTI_SZ ``Environment`` value
        # under the service's own key, which the SCM reads when it
        # starts the process. This is the Windows arm of §5's
        # env-default requirement for a service, which cannot go through
        # the .cmd wrapper because the SCM must be pointed at a real
        # executable.
        body.add("        <RegistryValue Root=\"HKLM\" Key=\"SYSTEM\\" &
          "CurrentControlSet\\Services\\" & xmlEscape(row.name) &
          "\" Name=\"Environment\" Type=\"multiString\" " &
          "Action=\"write\">\n")
        for (n, v) in row.environment:
          body.add("          <MultiStringValue>" & xmlEscape(n & "=" & v) &
            "</MultiStringValue>\n")
        body.add("        </RegistryValue>\n")

    body.add("      </Component>\n")
    if dirId notin componentsByDir:
      componentsByDir[dirId] = @[]
    componentsByDir[dirId].add(body)
    componentRefs.add(cmpId)

  # The PATH entry. §6's table calls out "service + PATH" for the MSI
  # arm specifically, because unlike a deb — which installs into a
  # directory already on PATH — an MSI installs into a product
  # directory that is not.
  block pathComponent:
    discard ensureDirNode(root, binDirRel)
    let dirId = dirIdFor(binDirRel)
    var body = ""
    body.add("      <Component Id=\"cmp_path_entry\" Guid=\"" &
      xmlEscape(dist.metadata.upgradeCode) & "\">\n")
    # A component with no file needs an explicit key path; a registry
    # value under the product's own key is the conventional one and
    # doubles as the uninstall marker.
    body.add("        <RegistryValue Root=\"HKLM\" Key=\"SOFTWARE\\" &
      xmlEscape(manufacturer) & "\\" & xmlEscape(dist.name) &
      "\" Name=\"InstallPath\" Type=\"string\" Value=\"[" & dirId &
      "]\" KeyPath=\"yes\" />\n")
    body.add("        <Environment Id=\"PathEntry\" Name=\"PATH\" " &
      "Value=\"[" & dirId & "]\" Permanent=\"no\" Part=\"last\" " &
      "Action=\"set\" System=\"yes\" />\n")
    body.add("      </Component>\n")
    if dirId notin componentsByDir:
      componentsByDir[dirId] = @[]
    componentsByDir[dirId].add(body)
    componentRefs.add("cmp_path_entry")

  result = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
  result.add("<!-- Generated by the reprobuild DSL packaging layer. -->\n")
  result.add("<Wix xmlns=\"http://schemas.microsoft.com/wix/2006/wi\"")
  if needsUtil:
    result.add(" xmlns:util=" &
      "\"http://schemas.microsoft.com/wix/UtilExtension\"")
  result.add(">\n")
  result.add("  <Product Id=\"*\" Name=\"" & xmlEscape(dist.name) &
    "\" Language=\"1033\" Version=\"" & msiProductVersion(dist) &
    "\" Manufacturer=\"" & xmlEscape(manufacturer) &
    "\" UpgradeCode=\"" & xmlEscape(dist.metadata.upgradeCode) & "\">\n")
  result.add("    <Package InstallerVersion=\"" & installerVersion &
    "\" Compressed=\"yes\" InstallScope=\"perMachine\"")
  if dist.metadata.summary.len > 0:
    result.add(" Comments=\"" &
      xmlEscape(dist.metadata.summary.splitLines()[0]) & "\"")
  result.add(" />\n")
  result.add("    <MajorUpgrade DowngradeErrorMessage=\"A newer version " &
    "of " & xmlEscape(dist.name) & " is already installed.\" />\n")
  # ``EmbedCab`` puts the payload inside the .msi, so the artifact is
  # ONE file. A .msi with an external .cab is two files that must travel
  # together, which is a much worse shape for a build-graph artifact and
  # for every distribution channel downstream.
  result.add("    <MediaTemplate EmbedCab=\"yes\" />\n")
  result.add("    <Directory Id=\"TARGETDIR\" Name=\"SourceDir\">\n")
  result.add("      <Directory Id=\"ProgramFiles64Folder\">\n")
  result.add("        <Directory Id=\"INSTALLFOLDER\" Name=\"" &
    xmlEscape(dist.name) & "\">\n")
  if "INSTALLFOLDER" in componentsByDir:
    for body in componentsByDir["INSTALLFOLDER"]:
      result.add(body)
  result.add(renderDirTree(root, 10, componentsByDir))
  result.add("        </Directory>\n")
  result.add("      </Directory>\n")
  result.add("    </Directory>\n")
  result.add("    <Feature Id=\"Complete\" Title=\"" &
    xmlEscape(dist.name) & "\" Level=\"1\">\n")
  for cmpId in componentRefs:
    result.add("      <ComponentRef Id=\"" & cmpId & "\" />\n")
  result.add("    </Feature>\n")
  result.add("  </Product>\n")
  result.add("</Wix>\n")

proc msiPackage*(dist: Distribution; site = noSite()): PackagedArtifact =
  ## Produce an ``.msi`` from the one ``Distribution`` definition.
  ##
  ## The MSI tree is rooted at the PREFIX, not at ``/``: the Windows
  ## install location is chosen by the installer at install time, so
  ## there is no build-time filesystem root for the payload to be
  ## relative to. That is the same ``"msi"`` variant the tarball uses,
  ## and it is why ``stageInstallTree`` takes a variant at all.
  let tree = stageInstallTree(dist, "msi", site)
  let wxsPath = dist.stagingRoot & "/gen-msi/" & dist.name & ".wxs"
  let wxsEdge = dslfs.writeText(wxsPath, wxsText(dist, tree),
    actionId = "pkg-msi-wxs-" & dist.name)

  let objPath = dist.stagingRoot & "/gen-msi/" & dist.name & ".wixobj"
  let extensions =
    if needsUtilExtension(dist): @["WixUtilExtension"] else: @[]
  let candleEdge = candleTool(
    noLogo = true,
    arch = dist.msiArchitecture,
    extensions = extensions,
    output = objPath,
    sources = @[wxsPath],
    actionId = "pkg-msi-candle-" & dist.name,
    after = @[wxsEdge] & tree.terminal,
    # The .wxs names every staged file as a ``File/@Source``. candle
    # does not read them — light does — but declaring them here as well
    # keeps the compile step invalidated by a changed payload, so a
    # rebuild after a binary changes cannot reuse a stale .wixobj.
    extraInputs = tree.stagedPaths())
  declareProducerTool(site, candleEdge.id, CandleSelector)

  let outPath = dist.outputDir & "/" & msiArtifactName(dist)
  let lightEdge = lightTool(
    noLogo = true,
    # ICE validation runs the produced database through the Windows
    # Installer service on the BUILD host, which makes the edge depend
    # on host state the engine can neither see nor fingerprint. It is a
    # verification step to run against the artifact, not a step in
    # producing it — and a build action that consults the local MSI
    # service is not hermetic in any sense reprobuild recognises.
    suppressValidation = true,
    # ICE/light warning 1076 is "ProductVersion's fourth field is
    # ignored"; the layer already drops the packaging release from the
    # product version deliberately (see ``msiProductVersion``), so the
    # warning is noise about a decision already made.
    suppressWarnings = @["1076"],
    extensions = extensions,
    output = outPath,
    objects = @[objPath],
    actionId = "pkg-msi-light-" & dist.name,
    after = @[candleEdge] & tree.terminal,
    extraInputs = tree.stagedPaths())
  declareProducerTool(site, lightEdge.id, LightSelector)

  PackagedArtifact(
    format: "msi",
    path: outPath,
    edge: lightEdge,
    toolSelectors: @[CandleSelector, LightSelector],
    tree: tree)

proc msiProducer(dist: Distribution;
                 site: ToolDependencySite): PackagedArtifact {.nimcall.} =
  msiPackage(dist, site)

registerProducer("msi",
  "Windows Installer database (tools: wix-candle, wix-light)",
  msiProducer)
