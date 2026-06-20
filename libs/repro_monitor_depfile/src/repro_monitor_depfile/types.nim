import std/[options]

type
  MonitorRecordKind* = enum
    mrProcessStart = 1
    mrProcessExec = 2
    mrProcessSpawn = 3
    mrFileOpen = 4
    mrFileRead = 5
    mrPathProbe = 6
    mrFileWrite = 7
    mrEventLoss = 8
    mrDirectoryEnumerate = 9
    mrBackendProfile = 10
    mrCapabilityGap = 11

  MonitorObservationKind* = enum
    moProcessStart = 1
    moExecute = 2
    moFileOpen = 3
    moFileRead = 4
    moPathProbe = 5
    moFileWrite = 6
    moEventLoss = 7
    moDirectoryEnumerate = 8
    moBackendProfile = 9
    moCapabilityGap = 10

  ProbeResult* = enum
    prUnknown = 0
    prAbsent = 1
    prExistingFile = 2
    prExistingDirectory = 3
    prExistingOther = 4

  MonitorCompleteness* = enum
    mcComplete
    mcIncomplete

  MonitorBackendFamily* = enum
    mbfMacosHooks
    mbfMacosEndpointSecurity
    mbfMacosHybrid
    mbfLinuxPreloadHooks
    mbfUnknown

  MonitorCapability* = enum
    mcapProcess
    mcapFileRead
    mcapFileWrite
    mcapPathProbe
    mcapDirectoryEnumerate
    mcapEventLoss
    mcapProcessTree
    mcapProcessExec
    mcapBackendProvenance
    mcapFileCreate
    mcapFileTruncate
    mcapFileAppend
    mcapEndpointSecurity
    mcapHybrid
    mcapRename
    mcapSymlink
    mcapLibraryLoad
    mcapAuthorizationEnforcement
    mcapPathMutation

  MonitorDiagnosticLevel* = enum
    mdlInfo
    mdlWarning
    mdlError

  MonitorDiagnostic* = object
    level*: MonitorDiagnosticLevel
    message*: string

  MonitorCapabilityGap* = object
    backendFamily*: MonitorBackendFamily
    capability*: MonitorCapability
    required*: bool
    reason*: string

  MonitorBackendProfile* = object
    profileName*: string
    backendFamily*: MonitorBackendFamily
    supportedCapabilities*: set[MonitorCapability]
    requiredCapabilities*: set[MonitorCapability]
    gaps*: seq[MonitorCapabilityGap]
    evidenceComplete*: bool
    diagnostics*: seq[MonitorDiagnostic]

  MonitorRecord* = object
    kind*: MonitorRecordKind
    observationKind*: MonitorObservationKind
    seq*: uint64
    osPid*: uint64
    parentOsPid*: uint64
    threadId*: uint64
    childOsPid*: uint64
    result*: int64
    flags*: uint32
    probeResult*: ProbeResult
    path*: string
    detail*: string

  MonitorSummary* = object
    recordCount*: uint64
    processCount*: uint64
    observationCount*: uint64
    eventLossCount*: uint64

  MonitorDepFile* = object
    version*: uint16
    producerVersion*: string
    backendFamily*: MonitorBackendFamily
    requiredFeatures*: set[MonitorCapability]
    completeness*: MonitorCompleteness
    profile*: MonitorBackendProfile
    capabilityGaps*: seq[MonitorCapabilityGap]
    summary*: MonitorSummary
    records*: seq[MonitorRecord]

  MonitorDepFileReaderOptions* = object
    allowUnknownOptionalRecords*: bool
    requireTrailerChecksum*: bool
    maxPathTableBytes*: uint64
    maxObservationCount*: uint64
    streamRecords*: bool

  MonitorDepFileReaderErrorKind* = enum
    mrMissingFile
    mrBadMagic
    mrUnsupportedVersion
    mrMissingRequiredFeature
    mrTruncated
    mrChecksumMismatch
    mrRecordOrderInvalid
    mrRecordLimitExceeded
    mrSemanticValidationFailed

  MonitorDepFileReaderError* = object of CatchableError
    kind*: MonitorDepFileReaderErrorKind

  MonitorDepFileReaderResult* = object
    depFile*: Option[MonitorDepFile]
    diagnostics*: seq[MonitorDiagnostic]

  FsSnoopOutputMode* = enum
    fsoNone
    fsoText
    fsoJsonl
    fsoBinaryStream

  FsSnoopStreamItemKind* = enum
    fsiChildStdout
    fsiChildStderr
    fsiProcessStarted
    fsiProcessExited
    fsiObservation
    fsiEventLoss
    fsiDiagnostic
    fsiSummary

  FsSnoopStreamItem* = object
    kind*: FsSnoopStreamItemKind
    record*: MonitorRecord
    diagnostic*: string
    summary*: MonitorSummary

  FsSnoopRequest* = object
    command*: seq[string]
    depFilePath*: string
    eventStreamPath*: string
    streamMode*: FsSnoopOutputMode
    passthroughChildStdout*: bool
    passthroughChildStderr*: bool
    # When ``captureChildStdio`` is true, fs-snoop creates a pipe for
    # the child's stdout+stderr (merged) and drains it on its own
    # thread/poll rather than inheriting the parent's stdio. This
    # mirrors how the reprobuild engine launches monitored actions
    # (osproc.startProcess with the default pipe-captured stdio +
    # pollCompletion drain), so integration tests can reproduce the
    # build-engine-only wedges without going through repro_cli_support.
    captureChildStdio*: bool
    # Optional path to dump the captured stdio for inspection. Empty
    # means stdio is read+discarded (mimicking the engine when it
    # only cares about completion).
    captureStdioPath*: string

const
  RmdfVersion* = 1'u16
  RmdfMagic* = "RMDF"
  RmdfTrailerMagic* = "RMDT"
  ReproMonitorDepfileProducer* = "repro_monitor_depfile_m11"

proc defaultMonitorDepFileReaderOptions*(): MonitorDepFileReaderOptions =
  MonitorDepFileReaderOptions(
    allowUnknownOptionalRecords: false,
    requireTrailerChecksum: true,
    maxPathTableBytes: 64'u64 * 1024'u64 * 1024'u64,
    # M9.R.15a.8 — qt6-base cmake configure produces > 10M file
    # observations when fs-snoop captures every probe under the
    # 50+-entry WSL-inherited Windows PATH (each ``find_program()``
    # call multiplies). Bumping to 100M unblocks the qt6-base configure
    # action. The reader-side observation array is sized lazily
    # (``seq[MonitorRecord]`` grows on push) so the higher cap doesn't
    # commit memory until the writer actually fills it.
    maxObservationCount: 100'u64 * 1000'u64 * 1000'u64,
    streamRecords: false)

proc raiseMonitorDepFileReaderError*(kind: MonitorDepFileReaderErrorKind;
                                     message: string) {.noreturn.} =
  var err = newException(MonitorDepFileReaderError, message)
  err.kind = kind
  raise err
