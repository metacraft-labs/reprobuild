## macOS installer applications: running a verified vendor installer
## unattended, CONFINED, into a staging prefix, and verifying what it
## produced (Store-And-Installation-Layout.md § macOS Application Bundles,
## "Installer applications"; issue
## `2026-10-14-macos-installer-applications-have-no-realizer`).
##
## Some vendors ship a macOS application only as an installer application
## (an install4j installer `.app` on a disk image: OpenWebStart). Its
## payload is in the installer's own format, so the product exists only
## after the installer runs. ``realizeInstallerApp`` performs the spec's
## steps 1 to 6 after the archive's digest matched:
##
## 1. copy the installer out of the archive (``macos_archives``) into private
##    scratch OUTSIDE the staging prefix;
## 2. verify it with trust checks 2 to 5 against the record's team
##    (``verifyAppBundleTeam``) -- an installer that fails is never run;
## 3. the staging prefix exists and is empty (the caller's contract);
## 4. run its main executable with the declared arguments under
##    ``/usr/bin/sandbox-exec`` (``runConfinedInstaller``);
## 5. refuse a non-zero exit, a missing product bundle, or anything in the
##    prefix root besides the placed item -- install4j given a directory it
##    cannot write silently installs to its default location and exits 0,
##    so the exit status alone proves nothing;
## 6. verify the product: ``appBundle`` passes checks 1 to 5, every other
##    bundle in the placed item (at any depth, not inside another bundle)
##    checks 2 to 5 against the team.
##
## Why a kernel sandbox and not only a scratch ``HOME``: measured on the
## OpenWebStart 1.14.0 installer, the unconfined installer wrote the user's
## real ``~/Library/Preferences/com.install4j.installations.plist`` (through
## ``java.util.prefs`` and ``cfprefsd``, which resolve the home directory
## from the user database, not ``$HOME``), and its Java runtime ignored
## ``TMPDIR``. ``sandbox-exec`` is deprecated by Apple but present and
## enforcing on macOS 26, and it is the only unprivileged confinement of an
## arbitrary process; a host without it refuses rather than run the
## installer unconfined. The sandbox is never relaxed (``AppTrustPolicy``
## relaxes only checks 4 and 5).
##
## The installer is started through the ambient-execution escape hatch
## (``uncontrolledStartProcess``), like every other tool the macOS
## application code drives: it is the vendor's code being run on purpose,
## confined by an absolute-path system tool on the SIP-protected volume, with
## an explicit environment and an argument vector (no shell).
##
## References:
## * sandbox-exec(1); the Sandbox Profile Language (SBPL) as used by Apple's
##   own profiles in ``/System/Library/Sandbox/Profiles`` (``deny``,
##   ``require-not``, ``require-any``, ``subpath``, ``literal``, ``regex``).
## * confstr(3), ``_CS_DARWIN_USER_TEMP_DIR`` -- the per-user temporary
##   directory (``/var/folders/.../T/``).
## * install4j unattended mode ``-q`` and ``-dir`` --
##   https://www.ej-technologies.com/resources/install4j/help/doc/installers/installerModes.html

import std/[monotimes, os, osproc, posix, streams, strtabs, strutils, times]
from repro_core/ambient_execution import uncontrolledStartProcess

import repro_home_resources/drivers/app_bundle
import ./macos_archives

const
  SandboxExecExe* = "/usr/bin/sandbox-exec"
    ## The confinement tool. Absolute: a PATH lookup could find something
    ## else, and the installer must never run unconfined.
  InstallerTimeout* = initDuration(minutes = 15)
    ## An installer still running after this is killed and the realization
    ## fails (spec step 4).
  InstallerPath* = "/usr/bin:/bin:/usr/sbin:/sbin"
    ## The installer's whole ``PATH``: the system volume only.
  OutputLimit = 64 * 1024
    ## The installer output kept for a diagnostic: its last 64 KiB.
  DarwinUserTempDirName = 65537.cint
    ## ``_CS_DARWIN_USER_TEMP_DIR`` from ``<unistd.h>``.

proc refuse(check, msg: string; output = "") {.noreturn.} =
  var e = newException(EInstallerApp, "installer application refused (" &
    check & "): " & msg &
    (if output.strip().len > 0: "\ninstaller output:\n" & output.strip()
     else: ""))
  e.check = check
  e.output = output
  raise e

proc confstr(name: cint; buf: cstring; len: csize_t): csize_t
  {.importc, header: "<unistd.h>".}

proc resolvedPath(path: string): string =
  ## The real path (``/private/var/...`` for ``/var/...``, ``/private/tmp``
  ## for ``/tmp``): the sandbox compares the paths a process writes, which
  ## the kernel has already resolved, so an unresolved path in the policy
  ## would match nothing.
  try: expandFilename(path)
  except OSError: absolutePath(path)

proc darwinUserTempDir*(): string =
  ## The per-user temporary directory, resolved (``confstr(
  ## _CS_DARWIN_USER_TEMP_DIR)``). install4j's native launcher unpacks its
  ## Java runtime there and cannot be pointed elsewhere, so the sandbox lets
  ## the installer write it (spec step 4). Raises ``OSError`` when the
  ## system does not report one.
  var buf = newString(1024)
  let needed = confstr(DarwinUserTempDirName, buf.cstring, csize_t(buf.len))
  if needed == 0 or int(needed) > buf.len:
    raise newOSError(osLastError(),
      "confstr(_CS_DARWIN_USER_TEMP_DIR) reported no per-user temp dir")
  buf.setLen(int(needed) - 1)
  resolvedPath(buf.strip(leading = false, chars = {'/'}))

proc sbplString(path: string): string =
  ## An SBPL string literal: ``"`` and ``\`` escaped.
  result = "\""
  for ch in path:
    if ch in {'"', '\\'}:
      result.add('\\')
    result.add(ch)
  result.add('"')

proc installerSandboxProfile*(writable: openArray[string]): string =
  ## The policy the installer runs under (spec step 4): everything is
  ## allowed except file writes outside ``writable`` (each a directory,
  ## already resolved) and the terminal and null devices, preference writes
  ## (``user-preference-write`` -- what ``cfprefsd`` checks before writing a
  ## domain on the process's behalf), and every network operation.
  var allowed = ""
  for dir in writable:
    allowed.add("\n    (subpath " & sbplString(dir) & ")")
  "(version 1)\n" &
    "(allow default)\n" &
    "(deny file-write* (require-not (require-any" & allowed &
    "\n    (literal \"/dev/null\")" &
    "\n    (regex #\"^/dev/tty\")" &
    "\n    (regex #\"^/dev/fd/\"))))\n" &
    "(deny user-preference-write)\n" &
    "(deny network*)\n"

proc userName(): string =
  ## The account name, from the user database (not the environment), for
  ## the installer's ``USER`` / ``LOGNAME``.
  let pw = getpwuid(getuid())
  if pw != nil and pw.pw_name != nil:
    return $pw.pw_name
  getEnv("USER")

proc mainExecutableOf(installerApp: string): string =
  ## ``Contents/MacOS/<CFBundleExecutable>`` (the bundle's name when the key
  ## is empty, as macOS does). The name must be one path component.
  var name = appBundleExecutableName(installerApp)
  if name.len == 0:
    name = extractFilename(installerApp).changeFileExt("")
  if '/' in name or name == "." or name == "..":
    refuse("executable", "the installer " & installerApp.escape &
      " declares the main executable " & name.escape &
      ", which is not a file name")
  result = installerApp / "Contents" / "MacOS" / name
  if symlinkExists(result) or not fileExists(result):
    refuse("executable", "the installer " & installerApp.escape &
      " has no main executable " & result.escape)

proc appendOutput(output: var string; chunk: string) =
  output.add(chunk)
  if output.len > 2 * OutputLimit:
    output = output[output.len - OutputLimit .. ^1]

proc drainAvailable(p: Process; output: var string) =
  ## Read what the installer has written so far without blocking: a pipe
  ## left unread would fill and stall it. (``osproc.hasData`` blocks until
  ## there is data, so readiness is polled here with a zero timeout.)
  var buf = newString(4096)
  while true:
    var fds = [TPollfd(fd: cint(p.outputHandle), events: POLLIN)]
    if posix.poll(fds[0].addr, 1, 0) <= 0 or
        (fds[0].revents and (POLLIN or POLLHUP)) == 0:
      break
    let n = posix.read(cint(p.outputHandle), buf[0].addr, buf.len)
    if n <= 0:
      break
    output.appendOutput(buf[0 ..< n])

proc proc_listchildpids(ppid: Pid; buffer: pointer; buffersize: cint): cint
  {.importc, header: "<libproc.h>".}
  ## libproc: the pids whose parent is ``ppid``; returns their number.

proc killInstallerTree(root: Pid) =
  ## Kill the installer and every process it started (install4j's launcher
  ## starts a Java runtime). Each process is stopped before its children are
  ## listed, so none can start another in between, and all are then killed;
  ## a child is listed before its parent dies, while it is still a child.
  var pending = @[root]
  var stopped: seq[Pid] = @[]
  while pending.len > 0:
    let pid = pending.pop()
    if pid in stopped:
      continue
    discard posix.kill(pid, SIGSTOP)
    stopped.add(pid)
    var children = newSeq[Pid](256)
    let n = proc_listchildpids(pid, children[0].addr,
      cint(children.len * sizeof(Pid)))
    for i in 0 ..< min(int(n), children.len):
      if children[i] > 0:
        pending.add(children[i])
  for pid in stopped:
    discard posix.kill(pid, SIGKILL)

proc runConfinedInstaller*(installerApp: string; args: openArray[string];
                           stagingPrefix, scratch: string;
                           timeout = InstallerTimeout;
                           sandboxExe = SandboxExecExe):
    tuple[exitCode: int; output: string; argv: seq[string]] =
  ## Run ``installerApp``'s main executable with ``args`` (already
  ## substituted) under ``sandboxExe`` (spec step 4). The process may write
  ## only under ``stagingPrefix``, ``scratch`` (which also holds its
  ## ``HOME`` and ``TMPDIR`` and the policy file) and the per-user temporary
  ## directory; it may not write preferences or use the network. Its
  ## environment is exactly ``PATH``, ``HOME``, ``TMPDIR``, ``USER`` and
  ## ``LOGNAME``; its stdin is a pipe closed before it starts reading (end
  ## of file, as ``/dev/null`` gives). Returns its exit status, its output
  ## (stdout and stderr, the last 64 KiB) and the argument vector run.
  ## Raises ``EInstallerApp`` (check "sandbox") when ``sandboxExe`` is not
  ## an executable, and (check "timeout") when the installer outlives
  ## ``timeout``, after killing it.
  if not sandboxExe.isAbsolute or not fileExists(sandboxExe):
    refuse("sandbox", sandboxExe & " is not present on this host; an " &
      "installer application is never run unconfined")
  let exe = mainExecutableOf(installerApp)
  let home = scratch / "home"
  let tmp = scratch / "tmp"
  createDir(home)
  createDir(tmp)
  let writable = @[resolvedPath(stagingPrefix), resolvedPath(scratch),
    darwinUserTempDir()]
  let profile = scratch / "installer.sb"
  writeFile(profile, installerSandboxProfile(writable))
  result.argv = @[sandboxExe, "-f", profile, exe] & @args
  let env = newStringTable(modeCaseSensitive)
  env["PATH"] = InstallerPath
  env["HOME"] = home
  env["TMPDIR"] = tmp & "/"
  let user = userName()
  env["USER"] = user
  env["LOGNAME"] = user
  var p: Process
  try:
    p = uncontrolledStartProcess(sandboxExe, workingDir = scratch,
      args = result.argv[1 .. ^1], env = env, options = {poStdErrToStdOut})
  except OSError as err:
    refuse("sandbox", "could not start " & sandboxExe & ": " & err.msg)
  try:
    p.inputStream.close()
    let deadline = getMonoTime() + timeout
    var code = -1
    while true:
      p.drainAvailable(result.output)
      code = p.peekExitCode()
      if code != -1:
        break
      if getMonoTime() >= deadline:
        killInstallerTree(Pid(p.processID))
        discard p.waitForExit()
        refuse("timeout", "the installer " & installerApp.escape &
          " was still running after " & $timeout & " and was killed",
          result.output)
      sleep(100)
    # What the installer wrote just before exiting. A child it left running
    # may hold the pipe open, so only what is already there is read.
    p.drainAvailable(result.output)
    result.exitCode = code
  finally:
    p.close()

proc substituteInstallDir*(args: openArray[string];
                           stagingPrefix: string): seq[string] =
  ## The declared arguments with ``${install_dir}`` replaced by the absolute
  ## staging prefix; nothing else is added (spec, "Declaring it").
  for a in args:
    result.add(a.replace("${install_dir}", stagingPrefix))

proc verifyProductBundles(item, mainBundlePath: string; teamId: string;
                          policy: AppTrustPolicy) =
  ## Spec step 6, second half: every bundle in the placed item other than
  ## the product bundle -- at any depth, not inside another bundle --
  ## passes checks 2 to 5 against ``teamId``. A bundle's own nested code is
  ## covered by its ``codesign --verify --deep``; symlinks are not followed.
  proc walk(dir: string) =
    for kind, path in walkDir(dir):
      if kind != pcDir:
        continue
      if path.endsWith(".app"):
        if path != mainBundlePath:
          discard verifyAppBundleTeam(path, teamId, policy)
      else:
        walk(path)
  if item.endsWith(".app"):
    return
  walk(item)

proc realizeInstallerApp*(archivePath: string; kind: AppArchiveKind;
                          installerApp: string; installerArgs: seq[string];
                          appBundle: string;
                          expected: AppBundleExpectation;
                          stagingPrefix, scratch: string;
                          policy: AppTrustPolicy = {};
                          timeout = InstallerTimeout;
                          sandboxExe = SandboxExecExe): seq[string] =
  ## Spec steps 1 to 6 for a digest-verified ``archivePath``. On success the
  ## staging prefix holds exactly the placed item (``placedItemOf``),
  ## verified; returns the argument vector that ran. ``scratch`` (outside
  ## the prefix) is filled and left for the caller to remove.
  ## ``stagingPrefix`` must exist and be empty. Raises ``EAppArchive``
  ## (the installer is not in the archive), ``EAppBundleRefused`` (the
  ## installer or the product failed a trust check) or ``EInstallerApp``.
  # Resolution refuses such a record already; re-checked here because this
  # is a library entry point and the path is joined to the prefix below.
  let productError = installerProductPathError(appBundle)
  if productError.len > 0:
    refuse("product", "appBundle " & appBundle.escape & " is not a " &
      "product path in the installed prefix: " & productError)
  let placed = placedItemOf(appBundle)
  # 1. The installer, out of the archive, outside the prefix.
  let installer = extractAppBundle(archivePath, kind, installerApp,
    scratch / "installer", scratch / "unpack")
  # 2. An installer that fails a trust check is never run.
  discard verifyAppBundleTeam(installer, expected.teamId, policy)
  # 3 + 4. Run it confined into the (empty) prefix.
  let prefix = resolvedPath(stagingPrefix)
  let run = runConfinedInstaller(installer,
    substituteInstallDir(installerArgs, prefix), prefix, scratch / "run",
    timeout, sandboxExe)
  result = run.argv
  # 5. The exit status is not trusted on its own.
  if run.exitCode != 0:
    refuse("exit-status", "the installer " & installerApp.escape &
      " exited " & $run.exitCode, run.output)
  let product = prefix / appBundle
  # The product is reached without crossing a symlink: an installer could
  # otherwise point the prefix at a bundle outside it.
  var walked = prefix
  for part in appBundle.replace('\\', '/').split('/'):
    walked = walked / part
    if symlinkExists(walked):
      refuse("product", "the installer made " & walked.escape & " a " &
        "symlink; the product must be installed in the staging prefix",
        run.output)
  if not dirExists(product):
    refuse("product", "the installer exited 0 but the staging prefix " &
      "holds no " & appBundle.escape & " (installer arguments: " &
      installerArgs.join(" ") & "; an installer that cannot write the " &
      "directory it is given may install somewhere else instead)",
      run.output)
  var stray: seq[string] = @[]
  for _, name in walkDir(prefix, relative = true):
    if name != placed.item:
      stray.add(name)
  if stray.len > 0:
    refuse("prefix-contents", "the staging prefix holds " &
      stray.join(", ") & " besides " & placed.item.escape &
      "; an installer application's prefix holds only its placed item",
      run.output)
  # 6. The product.
  discard verifyAppBundle(product, expected, policy)
  verifyProductBundles(prefix / placed.item, product, expected.teamId,
    policy)
