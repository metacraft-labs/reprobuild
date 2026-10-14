## Starting a long-lived background process on Windows that inherits ONLY the
## handles it is handed.
##
## WHY THIS EXISTS. `osproc.startProcess` calls `CreateProcessW` with
## `bInheritHandles = TRUE` and no handle list, so the child receives a copy of
## EVERY inheritable handle the caller holds -- not just the stdio pipes osproc
## made for it. For a short-lived child that is harmless. For the per-user
## daemon it is not: the daemon outlives the `repro` that started it, and any
## pipe that `repro` was writing into stays open for as long as the daemon
## runs. A caller that reads `repro`'s output to EOF -- CMake's `try_compile`,
## a test runner, `$(...)` in a shell -- then waits forever (reprobuild-specs
## issue 2026-10-10, "auto-started repro-daemon inherits the caller's output
## pipe on Windows"). The caller's own stdout is the usual culprit: whoever
## created that pipe made its write end inheritable so `repro` could receive
## it, and `repro` passes it straight on.
##
## WHAT IS DONE INSTEAD, and why this one of the possible answers:
##
##   * `STARTUPINFOEXW` with a `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` naming
##     exactly the child's stdin (`NUL`) and stdout/stderr (the daemon log,
##     appended, or `NUL` when it cannot be opened). `bInheritHandles` has to
##     be TRUE for the std handles to be valid in the child at all; the list is
##     what narrows "every inheritable handle" to these. This is the mechanism
##     `spec/Build-Engine-And-Scheduler.md`'s platform table names for
##     Windows, and it is the POSIX launch's guarantee (`launchWithFork`: stdin
##     from /dev/null, stdout/stderr to the log, every descriptor above 2
##     closed) restated for Windows.
##   * Not `bInheritHandles = FALSE`: the handles named in `STARTUPINFO` would
##     then be values from OUR handle table, meaningless in the child's.
##   * Not `DETACHED_PROCESS`: a daemon with no console makes every console
##     tool it later runs (compilers, linkers, shells) allocate a console of
##     its own, i.e. a window per action. `CREATE_NO_WINDOW` -- what osproc's
##     `poDaemon` already asked for -- gives it a hidden console that its
##     children share. Detachment from the caller's stdio is achieved by the
##     handle list, not by losing the console.
##
## The handles created here are closed again as soon as the child exists; the
## child holds its own duplicates.
##
## THE WORKING DIRECTORY IS THE SAME RULE APPLIED TO THE CURRENT DIRECTORY.
## With `lpCurrentDirectory = nil` the child starts in the caller's current
## directory, and Windows refuses to delete a directory that is some process's
## current directory. A daemon started from a CMake `TryCompile-<id>` scratch
## directory would keep it undeletable for its whole life (reprobuild-specs
## issue 2026-10-14, "auto-started repro-daemon holds its starter's working
## directory on Windows"). The caller therefore names the directory the child
## starts in, and it must be one the child owns.

when defined(windows):
  import std/[algorithm, os, strutils, winlean]
  from repro_core/paths import extendedPath

  const
    ExtendedStartupInfoPresent = 0x00080000'i32
    ProcThreadAttributeHandleList = 0x00020002'u
      ## `ProcThreadAttributeValue(ProcThreadAttributeHandleList = 2,
      ## Thread = FALSE, Input = TRUE, Additive = FALSE)`.
    FileAppendData = 0x0004'i32
    FileAttributeNormal = 0x00000080'i32

  type
    StartupInfoExW = object
      startupInfo: STARTUPINFO
      lpAttributeList: pointer

  proc initializeProcThreadAttributeList(lpAttributeList: pointer;
      dwAttributeCount, dwFlags: DWORD; lpSize: ptr csize_t): WINBOOL
      {.stdcall, dynlib: "kernel32",
        importc: "InitializeProcThreadAttributeList".}

  proc updateProcThreadAttribute(lpAttributeList: pointer; dwFlags: DWORD;
      attribute: uint; lpValue: pointer; cbSize: csize_t;
      lpPreviousValue: pointer; lpReturnSize: ptr csize_t): WINBOOL
      {.stdcall, dynlib: "kernel32", importc: "UpdateProcThreadAttribute".}

  proc deleteProcThreadAttributeList(lpAttributeList: pointer)
      {.stdcall, dynlib: "kernel32",
        importc: "DeleteProcThreadAttributeList".}

  proc createProcessExW(lpApplicationName, lpCommandLine: WideCString;
      lpProcessAttributes, lpThreadAttributes: ptr SECURITY_ATTRIBUTES;
      bInheritHandles: WINBOOL; dwCreationFlags: int32;
      lpEnvironment: pointer; lpCurrentDirectory: WideCString;
      lpStartupInfo: ptr StartupInfoExW;
      lpProcessInformation: var PROCESS_INFORMATION): WINBOOL
      {.stdcall, dynlib: "kernel32", importc: "CreateProcessW".}

  proc environmentBlock(env: openArray[(string, string)]): seq[uint16] =
    ## A `CREATE_UNICODE_ENVIRONMENT` block: `NAME=value\0` per entry, sorted
    ## case-insensitively by name as `CreateProcessW` documents, then a
    ## terminating `\0`.
    var entries = @env
    entries.sort(proc (a, b: (string, string)): int = cmpIgnoreCase(a[0], b[0]))
    for (key, value) in entries:
      let wide = newWideCString(key & "=" & value)
      for i in 0 ..< wide.len:
        result.add cast[uint16](wide[i])
      result.add 0'u16
    if entries.len == 0:
      result.add 0'u16
    result.add 0'u16

  proc openInheritable(path: string; access, creation, flags: int32): Handle =
    var inheritable = SECURITY_ATTRIBUTES(
      nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: nil,
      bInheritHandle: 1)
    let shareMode = FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE
    createFileW(newWideCString(path), access, shareMode, addr inheritable,
      creation, flags, 0)

  proc spawnWithOwnStdio*(exe: string; args: openArray[string];
                          env: openArray[(string, string)];
                          inheritEnvironment: bool;
                          logPath: string;
                          workingDir: string): int =
    ## Start `exe args` with a hidden console, stdin from `NUL` and
    ## stdout/stderr appended to `logPath` (or `NUL` when it cannot be
    ## opened), inheriting NO other handle of this process, in `workingDir`
    ## (an existing absolute directory; "" keeps this process's, which a
    ## long-lived child must not do -- see the module comment). The
    ## environment is exactly `env` unless `inheritEnvironment` is true, in
    ## which case it is this process's. Returns the child's pid; raises
    ## `OSError` when the process cannot be created. The child is not waited
    ## for and no handle to it is kept.
    var commandLine = quoteShellWindows(exe)
    for arg in args:
      commandLine.add(' ')
      commandLine.add(quoteShellWindows(arg))

    let nulIn = openInheritable("NUL", GENERIC_READ, OPEN_EXISTING, 0)
    if nulIn == INVALID_HANDLE_VALUE:
      raiseOSError(osLastError(), "cannot open NUL for the daemon's stdin")
    defer: discard closeHandle(nulIn)
    var output = INVALID_HANDLE_VALUE
    if logPath.len > 0:
      try:
        createDir(extendedPath(parentDir(logPath)))
      except CatchableError:
        discard
      output = openInheritable(extendedPath(logPath), FileAppendData,
        OPEN_ALWAYS, FileAttributeNormal)
    if output == INVALID_HANDLE_VALUE:
      output = openInheritable("NUL", GENERIC_WRITE, OPEN_EXISTING, 0)
    if output == INVALID_HANDLE_VALUE:
      raiseOSError(osLastError(), "cannot open NUL for the daemon's output")
    defer: discard closeHandle(output)

    # Each handle once: the list must not repeat one, and stdout and stderr
    # share theirs.
    var inherited = [nulIn, output]

    var attributeListSize: csize_t = 0
    discard initializeProcThreadAttributeList(nil, 1, 0,
      addr attributeListSize)
    var attributeList = newSeq[byte](int(attributeListSize))
    if initializeProcThreadAttributeList(addr attributeList[0], 1, 0,
        addr attributeListSize) == 0:
      raiseOSError(osLastError(), "InitializeProcThreadAttributeList")
    defer: deleteProcThreadAttributeList(addr attributeList[0])
    if updateProcThreadAttribute(addr attributeList[0], 0,
        ProcThreadAttributeHandleList, addr inherited[0],
        csize_t(sizeof(inherited)), nil, nil) == 0:
      raiseOSError(osLastError(),
        "UpdateProcThreadAttribute(PROC_THREAD_ATTRIBUTE_HANDLE_LIST)")

    var startup = StartupInfoExW(lpAttributeList: addr attributeList[0])
    startup.startupInfo.cb = int32(sizeof(StartupInfoExW))
    startup.startupInfo.dwFlags = STARTF_USESTDHANDLES
    startup.startupInfo.hStdInput = nulIn
    startup.startupInfo.hStdOutput = output
    startup.startupInfo.hStdError = output

    var environment: seq[uint16] = @[]
    if not inheritEnvironment:
      environment = environmentBlock(env)
    var flags = CREATE_NO_WINDOW or ExtendedStartupInfoPresent
    if not inheritEnvironment:
      flags = flags or CREATE_UNICODE_ENVIRONMENT

    let environmentPointer: pointer =
      if inheritEnvironment: nil else: addr environment[0]
    var spawned = PROCESS_INFORMATION()
    var applicationName = newWideCString(exe)
    var mutableCommandLine = newWideCString(commandLine)
    # The wide string is held by a named variable for the whole call: a
    # temporary would be destroyed right after its pointer was taken.
    var currentDirectoryStorage = newWideCString(workingDir)
    let currentDirectory: WideCString =
      if workingDir.len > 0: toWideCString(currentDirectoryStorage) else: nil
    let created = createProcessExW(applicationName, mutableCommandLine,
      nil, nil, 1, flags, environmentPointer, currentDirectory, addr startup,
      spawned)
    if created == 0:
      raiseOSError(osLastError(), "CreateProcessW " & exe)
    discard closeHandle(spawned.hThread)
    discard closeHandle(spawned.hProcess)
    int(spawned.dwProcessId)
