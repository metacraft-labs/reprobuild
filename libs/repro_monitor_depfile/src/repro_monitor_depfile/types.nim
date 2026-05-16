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

  MonitorObservationKind* = enum
    moProcessStart = 1
    moExecute = 2
    moFileOpen = 3
    moFileRead = 4
    moPathProbe = 5
    moFileWrite = 6
    moEventLoss = 7
    moDirectoryEnumerate = 8

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
    mbfUnknown

  MonitorCapability* = enum
    mcapProcess
    mcapFileRead
    mcapFileWrite
    mcapPathProbe
    mcapDirectoryEnumerate
    mcapEventLoss

  MonitorDiagnosticLevel* = enum
    mdlInfo
    mdlWarning
    mdlError

  MonitorDiagnostic* = object
    level*: MonitorDiagnosticLevel
    message*: string

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
    maxObservationCount: 10'u64 * 1000'u64 * 1000'u64,
    streamRecords: false)

proc raiseMonitorDepFileReaderError*(kind: MonitorDepFileReaderErrorKind;
                                     message: string) {.noreturn.} =
  var err = newException(MonitorDepFileReaderError, message)
  err.kind = kind
  raise err
