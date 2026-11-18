import std/[os, strutils]

import repro_core
import repro_core/owned_directory
import repro_daemon_core/ipc
from repro_interface_artifacts import writeTaggedTarballArchiveDetail,
  readTaggedTarballArchiveDetail
from repro_project_dsl import TarballArchiveDetail
export ipc, TarballArchiveDetail, OwnedDirectoryError

when defined(posix):
  import std/posix
when defined(windows):
  import blake3

const
  StoreDaemonProtocolVersion* = 9'u16
    ## v8: the external-realize body carries ``nixRequesterDir``, the
    ## client's working directory, which a relative ``expressionFile`` and a
    ## ``.#`` selector are resolved against. A v7 peer reading a v8 body
    ## would read the directory's length as the next field.
    ##
    ## v9: the external-realize body also carries ``closureEntries``, the
    ## closure manifest's canonical lines inlined by the client. A record
    ## from a published artifact has no manifest FILE for the daemon to open,
    ## so a v8 peer would realize it without its closure. A v8 peer reading
    ## a v9 body would read the entry count as ``stripComponents``.
    ##
    ## v7: the external-realize body carries the record's whole
    ## ``archiveDetail`` (``TarballArchiveDetail``, version-tagged) where v6
    ## carried only its ``version``. A v6 peer reading a v7 body would read
    ## the detail's tag and first fields as ``version`` and
    ## ``stripComponents``.
    ##
    ## v6: the external-realize body also carries ``version``. Same
    ## reasoning as every bump below: a v5 peer reading a v6 body would read
    ## the version string's length as ``stripComponents``.
    ##
    ## v5: the external-realize body also carries ``closureManifest``. Same
    ## reasoning as every bump below: a v4 peer reading a v5 body would read
    ## the manifest string's length as ``stripComponents``.
    ##
    ## v4: the external-realize body also carries ``launcher``. Same
    ## reasoning as every bump below: a v3 peer reading a v4 body would
    ## read the launcher string's length as ``stripComponents``.
    ##
    ## v3: the external-realize body also carries ``nonRedistributable``.
    ## Same reasoning as the v2 bump below: a v2 peer reading a v3 body
    ## would read the flag byte as the first byte of ``stripComponents``.
    ##
    ## v2: the external-realize body carries ``executableAlias`` and
    ## ``prunePaths``. The bump is what makes the change safe: the frame is
    ## positional, so a v1 peer reading a v2 body would not fail — it would
    ## read the alias string as ``stripComponents`` and realize a different
    ## prefix. The handshake rejects the mismatch instead.
  StoreDaemonProfileDev* = "development-store"
  StoreDaemonCapabilities* = "realize,register_root,query,gc,status"
  FrameMagic = "RBSD"

type
  StoreDaemonMessageKind* = enum
    sdkHello = 1
    sdkHelloAck = 2
    sdkStatus = 3
    sdkStatusResponse = 4
    sdkSyntheticRealize = 5
    sdkRealizeResponse = 6
    sdkReleaseRoot = 7
    sdkReleaseRootAck = 8
    sdkShutdown = 9
    sdkShutdownAck = 10
    sdkNixRealize = 11
    sdkTarballRealize = 12
    sdkError = 255

  StoreDaemonStatus* = object
    running*: bool
    protocolVersion*: uint16
    daemonProfile*: string
    endpoint*: string
    storeRoot*: string
    pid*: int64
    uptimeSeconds*: int64
    realizedPrefixCount*: int
    rootCount*: int
    pendingRealizationCount*: int

  StoreDaemonRealizeResult* = object
    status*: string
    realizedPrefixPath*: string
    realizationHashHex*: string
    rootId*: string
    writerMode*: string
    installMethod*: string
    selectedStorePath*: string
    profileArtifactPath*: string

  SyntheticRealizeRequest* = object
    storeRoot*: string
    realizationIdHex*: string
    packageName*: string
    version*: string
    payload*: string
    holderId*: string
    rootId*: string
    delayMs*: int

  StoreDaemonExternalRealizeRequest* = object
    storeRoot*: string
    holderId*: string
    rootId*: string
    rawConstraint*: string
    packageSelector*: string
    executableName*: string
    packageId*: string
    declaredExecutablePath*: string
    lockIdentity*: string
    nixSelector*: string
    nixExpressionFile*: string
    nixRequesterDir*: string
      ## Absolute working directory of the requesting client. The daemon's
      ## own directory is not the project's, so a relative ``nixExpressionFile``
      ## and a ``.#`` selector must not be resolved against it.
    nixpkgsRef*: string
    nixpkgsRev*: string
    nixpkgsNarHash*: string
    tarballUrl*: string
    tarballMirrors*: seq[string]
    tarballSha256*: string
    archiveType*: string
    executableAlias*: string
      ## Second name the realized executable is exposed under.
    prunePaths*: seq[string]
      ## Prefix-relative paths realize drops after extraction.
    nonRedistributable*: bool
      ## When true the daemon must realize but never publish this prefix.
    launcher*: string
      ## Interpreter a script payload is run through; empty for a program.
    closureEntries*: seq[string]
      ## v9: the closure manifest's canonical lines, inlined from a published
      ## artifact's record; empty when the closure is the file in
      ## ``closureManifest`` or there is none.
    closureManifest*: string
      ## Recipe-relative manifest of additional archives to unpack; empty
      ## when the prefix is exactly one archive.
      ##
      ## Both of these travel with the request for the same reason every
      ## other field does: the daemon rebuilds the provisioning from this
      ## message alone (``useDefForTarball``), so a field that does not
      ## cross the socket does not exist on the realizing side. Dropping
      ## either does not fail — it produces a DIFFERENT prefix under a
      ## different cache key than the same realize performed in-process,
      ## which is the one way this path can go wrong silently.
    archiveDetail*: TarballArchiveDetail
      ## The selected tarball record's archive-realization detail, whole:
      ## its upstream ``version``, its ``sha512``/``sha1`` digests, its
      ## install method and every installer field. All of it is input to
      ## the daemon's selection and realization of the record it rebuilds:
      ##
      ##   * selection filters by the ``uses:`` range in ``rawConstraint``,
      ##     judged against ``version`` -- an unversioned record satisfies
      ##     no range;
      ##   * a record pinned only by ``sha512`` or ``sha1`` carries an empty
      ##     ``tarballSha256``, and without the detail it arrives with no
      ##     digest at all;
      ##   * a record with an installer feature (``extractPath``,
      ##     ``installMethod``, ``appBundle`` ...) without the detail is a
      ##     plain archive, extracted as-is into a different prefix.
      ##
      ## It travels as one unit, through the interface-artifact codec, so a
      ## field added to the detail reaches the daemon without a change here.
    stripComponents*: int

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc textOf(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc writeBool(buf: var seq[byte]; value: bool) =
  buf.add(if value: 1'u8 else: 0'u8)

proc readBool(buf: openArray[byte]; pos: var int): bool =
  if pos >= buf.len:
    raise newException(ValueError, "truncated boolean")
  result = buf[pos] != 0
  inc pos

proc writeI64(buf: var seq[byte]; value: int64) =
  buf.writeU64Le(uint64(value))

proc readI64(buf: openArray[byte]; pos: var int): int64 =
  int64(buf.readU64Le(pos))

proc writeStringSeq(buf: var seq[byte]; values: openArray[string]) =
  buf.writeU32Le(uint32(values.len))
  for value in values:
    buf.writeString(value)

proc readStringSeq(buf: openArray[byte]; pos: var int): seq[string] =
  let count = readElementCount(buf, pos, 4)
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = buf.readString(pos)

proc writeFrame*(conn: IpcConn; kind: StoreDaemonMessageKind;
                 body: openArray[byte] = []) =
  var frame: seq[byte] = @[]
  for ch in FrameMagic:
    frame.add(byte(ord(ch)))
  frame.writeU16Le(StoreDaemonProtocolVersion)
  frame.writeU16Le(uint16(ord(kind)))
  frame.writeU32Le(uint32(body.len))
  frame.add(body)
  conn.sendByteString(frame.textOf())

proc readFrame*(conn: IpcConn): tuple[kind: StoreDaemonMessageKind;
                                      body: seq[byte]] =
  let header = conn.recvBytesExact(12)
  for i in 0 ..< 4:
    if header[i] != byte(ord(FrameMagic[i])):
      raise newException(ValueError, "bad store-daemon frame magic")
  var pos = 4
  let version = header.readU16Le(pos)
  if version != StoreDaemonProtocolVersion:
    raise newException(ValueError,
      "unsupported store-daemon protocol version: " & $version)
  let kindRaw = int(header.readU16Le(pos))
  let bodyLen = int(header.readU32Le(pos))
  result.kind = StoreDaemonMessageKind(kindRaw)
  result.body = conn.recvBytesExact(bodyLen)

proc helloBody*(clientName: string): seq[byte] =
  result.writeU16Le(StoreDaemonProtocolVersion)
  result.writeString(clientName)
  result.writeI64(int64(getCurrentProcessId()))

proc parseHello*(body: openArray[byte]): tuple[version: uint16;
    clientName: string; pid: int64] =
  var pos = 0
  result.version = body.readU16Le(pos)
  result.clientName = body.readString(pos)
  result.pid = body.readI64(pos)

proc helloAckBody*(profile, storeRoot: string; pid: int64): seq[byte] =
  result.writeU16Le(StoreDaemonProtocolVersion)
  result.writeString(profile)
  result.writeString(storeRoot)
  result.writeString(StoreDaemonCapabilities)
  result.writeI64(pid)

proc parseHelloAck*(body: openArray[byte]): tuple[version: uint16;
    profile: string; storeRoot: string; capabilities: string; pid: int64] =
  var pos = 0
  result.version = body.readU16Le(pos)
  result.profile = body.readString(pos)
  result.storeRoot = body.readString(pos)
  result.capabilities = body.readString(pos)
  result.pid = body.readI64(pos)

proc statusBody*(status: StoreDaemonStatus): seq[byte] =
  result.writeBool(status.running)
  result.writeU16Le(status.protocolVersion)
  result.writeString(status.daemonProfile)
  result.writeString(status.endpoint)
  result.writeString(status.storeRoot)
  result.writeI64(status.pid)
  result.writeI64(status.uptimeSeconds)
  result.writeU32Le(uint32(status.realizedPrefixCount))
  result.writeU32Le(uint32(status.rootCount))
  result.writeU32Le(uint32(status.pendingRealizationCount))

proc parseStatusBody*(body: openArray[byte]): StoreDaemonStatus =
  var pos = 0
  result.running = body.readBool(pos)
  result.protocolVersion = body.readU16Le(pos)
  result.daemonProfile = body.readString(pos)
  result.endpoint = body.readString(pos)
  result.storeRoot = body.readString(pos)
  result.pid = body.readI64(pos)
  result.uptimeSeconds = body.readI64(pos)
  result.realizedPrefixCount = int(body.readU32Le(pos))
  result.rootCount = int(body.readU32Le(pos))
  result.pendingRealizationCount = int(body.readU32Le(pos))

proc syntheticBody*(req: SyntheticRealizeRequest): seq[byte] =
  result.writeString(req.storeRoot)
  result.writeString(req.realizationIdHex)
  result.writeString(req.packageName)
  result.writeString(req.version)
  result.writeString(req.payload)
  result.writeString(req.holderId)
  result.writeString(req.rootId)
  result.writeU32Le(uint32(req.delayMs))

proc parseSyntheticBody*(body: openArray[byte]): SyntheticRealizeRequest =
  var pos = 0
  result.storeRoot = body.readString(pos)
  result.realizationIdHex = body.readString(pos)
  result.packageName = body.readString(pos)
  result.version = body.readString(pos)
  result.payload = body.readString(pos)
  result.holderId = body.readString(pos)
  result.rootId = body.readString(pos)
  result.delayMs = int(body.readU32Le(pos))

proc realizeResponseBody*(res: StoreDaemonRealizeResult): seq[byte] =
  result.writeString(res.status)
  result.writeString(res.realizedPrefixPath)
  result.writeString(res.realizationHashHex)
  result.writeString(res.rootId)
  result.writeString(res.writerMode)
  result.writeString(res.installMethod)
  result.writeString(res.selectedStorePath)
  result.writeString(res.profileArtifactPath)

proc parseRealizeResponseBody*(body: openArray[byte]):
    StoreDaemonRealizeResult =
  var pos = 0
  result.status = body.readString(pos)
  result.realizedPrefixPath = body.readString(pos)
  result.realizationHashHex = body.readString(pos)
  result.rootId = body.readString(pos)
  result.writerMode = body.readString(pos)
  if pos < body.len:
    result.installMethod = body.readString(pos)
    result.selectedStorePath = body.readString(pos)
    result.profileArtifactPath = body.readString(pos)

proc externalRealizeBody*(req: StoreDaemonExternalRealizeRequest): seq[byte] =
  result.writeString(req.storeRoot)
  result.writeString(req.holderId)
  result.writeString(req.rootId)
  result.writeString(req.rawConstraint)
  result.writeString(req.packageSelector)
  result.writeString(req.executableName)
  result.writeString(req.packageId)
  result.writeString(req.declaredExecutablePath)
  result.writeString(req.lockIdentity)
  result.writeString(req.nixSelector)
  result.writeString(req.nixExpressionFile)
  result.writeString(req.nixRequesterDir)
  result.writeString(req.nixpkgsRef)
  result.writeString(req.nixpkgsRev)
  result.writeString(req.nixpkgsNarHash)
  result.writeString(req.tarballUrl)
  result.writeStringSeq(req.tarballMirrors)
  result.writeString(req.tarballSha256)
  result.writeString(req.archiveType)
  result.writeString(req.executableAlias)
  result.writeStringSeq(req.prunePaths)
  result.writeU32Le(if req.nonRedistributable: 1'u32 else: 0'u32)
  result.writeString(req.launcher)
  result.writeString(req.closureManifest)
  result.writeStringSeq(req.closureEntries)
  result.writeTaggedTarballArchiveDetail(req.archiveDetail)
  result.writeU32Le(uint32(max(req.stripComponents, 0)))

proc parseExternalRealizeBody*(body: openArray[byte]):
    StoreDaemonExternalRealizeRequest =
  var pos = 0
  result.storeRoot = body.readString(pos)
  result.holderId = body.readString(pos)
  result.rootId = body.readString(pos)
  result.rawConstraint = body.readString(pos)
  result.packageSelector = body.readString(pos)
  result.executableName = body.readString(pos)
  result.packageId = body.readString(pos)
  result.declaredExecutablePath = body.readString(pos)
  result.lockIdentity = body.readString(pos)
  result.nixSelector = body.readString(pos)
  result.nixExpressionFile = body.readString(pos)
  result.nixRequesterDir = body.readString(pos)
  result.nixpkgsRef = body.readString(pos)
  result.nixpkgsRev = body.readString(pos)
  result.nixpkgsNarHash = body.readString(pos)
  result.tarballUrl = body.readString(pos)
  result.tarballMirrors = body.readStringSeq(pos)
  result.tarballSha256 = body.readString(pos)
  result.archiveType = body.readString(pos)
  result.executableAlias = body.readString(pos)
  result.prunePaths = body.readStringSeq(pos)
  result.nonRedistributable = body.readU32Le(pos) != 0'u32
  result.launcher = body.readString(pos)
  result.closureManifest = body.readString(pos)
  result.closureEntries = body.readStringSeq(pos)
  result.archiveDetail = body.readTaggedTarballArchiveDetail(pos)
  result.stripComponents = int(body.readU32Le(pos))

proc releaseRootBody*(holderId, rootId: string): seq[byte] =
  result.writeString(holderId)
  result.writeString(rootId)

proc parseReleaseRootBody*(body: openArray[byte]):
    tuple[holderId: string; rootId: string] =
  var pos = 0
  result.holderId = body.readString(pos)
  result.rootId = body.readString(pos)

proc errorBody*(message: string): seq[byte] =
  result.writeString(message)

proc parseErrorBody*(body: openArray[byte]): string =
  var pos = 0
  body.readString(pos)

proc currentUid*(): int64 =
  when defined(posix):
    int64(getuid())
  else:
    0'i64

const DevEndpointDirRole = OwnedDirectoryRole(
  noun: "dev store daemon endpoint directory",
  exposure: "another account could put its own socket there and answer " &
    "for the daemon",
  remedy: "remove it if it is yours, or set XDG_RUNTIME_DIR or " &
    "REPROSTORED_ENDPOINT to a directory only you can write")
  ## How a refusal of the private endpoint directory is worded
  ## (``repro_core/owned_directory``).

when defined(posix):
  proc devEndpointLeaf(): string = "reprostore-" & $currentUid() & ".sock"

  proc privateDevRuntimeDir*(): string =
    ## The per-user directory the default endpoint and the status file live
    ## in when ``XDG_RUNTIME_DIR`` is unset: ``<tmp>/reprostore-<uid>``, or
    ## ``/tmp/reprostore-<uid>`` when a socket in the former would not fit
    ## the platform's Unix-socket address (``ipcEndpointFits``).
    ##
    ## The socket is never placed directly in the shared temporary
    ## directory: anyone can create entries there, so the first to bind the
    ## predictable name would answer for the daemon. This directory is
    ## created ``0700`` and admitted only when it is this user's and private
    ## (``admitDevRuntimeDir``). reprobuild-pm
    ## ``spec/Store-Daemon-And-Multi-User-Coordination.md`` §"IPC Protocol",
    ## "Development socket paths" and "The per-user endpoint directory is
    ## private".
    ##
    ## ``$TMPDIR`` has no length limit -- the suite's
    ## ``~/.cache/reprobuild-test-tmp/<slot>``, a ``nix-shell`` session
    ## directory -- and the socket must fit what ``std/net`` binds (107 bytes
    ## on Linux, 91 on macOS; ``repro_core/paths.unixSocketPathMaxLen``) with
    ## room beside it for ``bindIpcListener``'s staging name. Where it would
    ## not, the directory goes under ``/tmp`` instead, as
    ## ``repro_core/paths.runquotaEndpointPath`` does for its own sockets.
    let dirLeaf = "reprostore-" & $currentUid()
    result = getTempDir() / dirLeaf
    if not ipcEndpointFits(result / devEndpointLeaf()):
      result = "/tmp" / dirLeaf

  proc xdgRuntimeDirSet(): bool = getEnv("XDG_RUNTIME_DIR").len > 0

proc devRuntimeDir*(): string =
  ## The per-user directory holding the dev daemon's default endpoint and
  ## its status file: ``$XDG_RUNTIME_DIR`` when set (the session manager
  ## creates it ``0700`` for the user, so it is used as given), otherwise
  ## ``privateDevRuntimeDir``. Windows: ``%LOCALAPPDATA%\repro``.
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0:
      local / "repro"
    else:
      getTempDir()
  else:
    if xdgRuntimeDirSet(): getEnv("XDG_RUNTIME_DIR")
    else: privateDevRuntimeDir()

proc admitDevRuntimeDir*() =
  ## Create the private per-user directory if it is missing, and admit it
  ## only when ``lstat`` says it is a real directory owned by this user with
  ## no group or other permission. A no-op when ``XDG_RUNTIME_DIR`` is set
  ## and on Windows. Never repairs an existing directory.
  ##
  ## Raises ``OwnedDirectoryError`` for a refusal (naming the directory,
  ## its owner and its mode) and ``OSError`` when it cannot be created or
  ## inspected. The daemon calls it before it binds or writes its status
  ## file; a client before it connects to a default endpoint
  ## (``admitDevEndpointDir``).
  when defined(posix):
    if not xdgRuntimeDirSet():
      ensureOwnedDirectory(privateDevRuntimeDir(), privateDir = true,
        DevEndpointDirRole)

proc endpointIsInPrivateDevRuntimeDir*(endpoint: string): bool =
  ## Whether ``endpoint`` lies in the product-created private directory,
  ## which is the case for the default endpoint whenever
  ## ``XDG_RUNTIME_DIR`` is unset, however it reached the caller (the
  ## default, ``--endpoint`` from ``startDevDaemon``'s self-spawn, or an
  ## override that happens to name it).
  when defined(posix):
    not xdgRuntimeDirSet() and
      os.normalizedPath(parentDir(endpoint)) ==
        os.normalizedPath(privateDevRuntimeDir())
  else:
    false

proc admitDevEndpointDir*(endpoint: string) =
  ## ``admitDevRuntimeDir`` when ``endpoint`` lies in the private directory.
  ## Any other endpoint's directory -- ``$XDG_RUNTIME_DIR``, or an explicit
  ## ``REPROSTORED_ENDPOINT`` / ``--endpoint`` -- is not checked: it is the
  ## session manager's or the caller's choice. The peer check still applies
  ## to every endpoint (``client.connectDevDaemon``).
  if endpointIsInPrivateDevRuntimeDir(endpoint):
    admitDevRuntimeDir()

when defined(windows):
  proc devPipeUserTag*(userSid: string): string =
    ## The first 16 lowercase hex characters of the BLAKE3-256 digest of the
    ## user's string SID: the per-user part of the dev pipe name, so two
    ## users on one machine never contend for one name.
    blake3.digest(userSid).toHex()[0 ..< 16].toLowerAscii()

proc defaultDevEndpoint*(): string =
  ## The dev store daemon's endpoint (reprobuild-pm
  ## ``spec/Store-Daemon-And-Multi-User-Coordination.md`` §"IPC Protocol",
  ## "Development socket paths"):
  ##
  ## * ``REPROSTORED_ENDPOINT``, verbatim, on every platform;
  ## * POSIX: ``$XDG_RUNTIME_DIR/reprostore-<uid>.sock`` when that is set,
  ##   verbatim (an over-long one is reported by ``bindIpcListener``,
  ##   naming the limit, rather than moved); otherwise
  ##   ``reprostore-<uid>.sock`` in ``privateDevRuntimeDir``;
  ## * Windows: ``\\.\pipe\reprostored-dev-<devPipeUserTag(SID)>``.
  ##
  ## Where the endpoint is does not make whoever listens there trusted:
  ## every client authenticates the listener from the kernel's peer
  ## credentials (``client.connectDevDaemon``).
  let override = getEnv("REPROSTORED_ENDPOINT")
  if override.len > 0:
    return override
  when defined(windows):
    let sid =
      try: ipcOwnIdentity().sid
      except IpcPeerIdentityError as err:
        raise newException(IpcPeerIdentityError,
          "cannot derive the dev store daemon's pipe name: " & err.msg)
    "\\\\.\\pipe\\reprostored-dev-" & devPipeUserTag(sid)
  else:
    devRuntimeDir() / devEndpointLeaf()

proc statusFileForEndpoint*(endpoint: string): string =
  ## The status file of the daemon at ``endpoint``: the endpoint's last
  ## component with ``.status``, in ``devRuntimeDir`` (which the daemon
  ## admits before writing it, ``admitDevRuntimeDir``).
  let leaf = endpoint.extractFilename
  devRuntimeDir() / (leaf & ".status")

proc defaultDevStoreRoot*(): string =
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0:
      local / "repro" / "reprostored-dev" / "store"
    else:
      getEnv("USERPROFILE") / "AppData" / "Local" / "repro" /
        "reprostored-dev" / "store"
  elif defined(macosx):
    getEnv("HOME") / "Library" / "Caches" / "repro" / "reprostored-dev" /
      "store"
  else:
    let xdg = getEnv("XDG_CACHE_HOME")
    let base = if xdg.len > 0: xdg else: getEnv("HOME") / ".cache"
    base / "repro" / "reprostored-dev" / "store"

proc devStoreRoot*(explicit = ""): string =
  if explicit.len > 0:
    explicit
  else:
    defaultDevStoreRoot()

proc parsePrefixIdHex*(hex: string): array[32, byte] =
  if hex.len != 64:
    raise newException(ValueError,
      "realization id must be 64 lowercase hex chars")
  for i in 0 ..< 32:
    result[i] = byte(parseHexInt(hex[i * 2 .. i * 2 + 1]))

proc prefixIdHex(bytes: openArray[byte]): string =
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())
