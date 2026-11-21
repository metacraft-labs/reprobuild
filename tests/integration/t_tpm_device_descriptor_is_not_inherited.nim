## The TPM device descriptor does not outlive this process through a
## child.
##
## ## The claim
##
## `/dev/tpm0` admits one caller at a time, so a process holding it open
## locks every other user of the machine's TPM out. The transport that
## opens it is written to release it — `transportClose` closes the
## descriptor — but releasing it is not enough on its own: a descriptor
## without `FD_CLOEXEC` is inherited by every process spawned while it
## is open, and an inherited copy keeps the device open after the owner
## has closed its own. The exclusion then outlives the agent, held by a
## child nobody is looking at, and the remedy an operator would reach
## for — restart the agent — does not lift it.
##
## So the two cases below check the two halves of that:
##
## 1. **The descriptor carries `FD_CLOEXEC`.** Read back with
##    `fcntl(F_GETFD)` from the descriptor the transport actually
##    opened, which is found by comparing this process's open
##    descriptors across the call rather than by reaching into the
##    transport.
## 2. **A spawned process does not have it.** The same descriptor
##    number, resolved through `/proc/self/fd` inside a real child
##    process while the transport is open, does not name the file the
##    transport opened.
##
## Case 1 is the mechanism and case 2 is the consequence. Case 1 alone
## would pass against an implementation that set the flag on the wrong
## descriptor, and case 2 alone would pass on a host where the spawn
## helper happened to close descriptors for its own reasons.
##
## The first case also carries its own control: the same probe is run
## against a descriptor this file opens *without* the flag, so a pass
## means the probe can tell the difference rather than that it answers
## "set" to everything.
##
## ## Mocking
##
## No TPM and no TPM device node. The path handed to the transport is an
## ordinary file in a temporary directory, and that is not a stand-in
## for a device: the subject is the FLAGS the descriptor is opened with,
## which are an argument to `open(2)` and do not depend on what is at
## the other end of it. A device node would also make the case
## unrunnable on every host without a TPM, which is every development
## host here, and would test nothing more. Nothing in this file performs
## a TPM transaction; the live command path is covered by
## `t_tpm_quote_comes_from_the_tpm`.

import std/[os, osproc, posix, strutils, unittest]

import repro_attest

const
  MaxProbedDescriptor = 1024
    ## `FD_SETSIZE` on Linux, and far above anything a test process
    ## holds. The probe is a syscall per number, so the whole sweep is
    ## cheaper than the `open` it is measuring.

proc openDescriptors(): seq[cint] =
  ## Every descriptor number this process currently holds.
  ##
  ## Asked of the kernel through `fcntl` rather than read out of
  ## `/proc/self/fd`, because the answer is then the same on every
  ## POSIX host and needs no filesystem to be mounted.
  result = @[]
  for fd in cint(0) ..< cint(MaxProbedDescriptor):
    if fcntl(fd, F_GETFD) != -1:
      result.add fd

proc hasCloseOnExec(fd: cint): bool =
  let flags = fcntl(fd, F_GETFD)
  doAssert flags != -1,
    "descriptor " & $fd & " is not open, so nothing can be concluded " &
    "about its flags: " & $strerror(errno)
  (flags and FD_CLOEXEC) != 0

suite "the TPM device descriptor is the agent's alone":

  test "the transport opens the device close-on-exec":
    let dir = getTempDir() / ("repro-tpm-cloexec-" & $getCurrentProcessId())
    removeDir(dir)
    createDir(dir)
    let path = dir / "tpm-device-stand-in"
    writeFile(path, "")
    try:
      let before = openDescriptors()
      let transport = newTpm2CharDeviceTransport(path)
      try:
        var opened: seq[cint] = @[]
        for fd in openDescriptors():
          if fd notin before: opened.add fd
        # One descriptor, so the flag below is read from the one the
        # transport opened and not from something that happened to be
        # open already.
        check opened.len == 1
        check hasCloseOnExec(opened[0])
      finally:
        transport.transportClose()

      # The control. `open` without the flag is what the defect was,
      # and the probe has to report it as such — otherwise the case
      # above would pass whatever the transport did.
      let inherited = posix.open(path.cstring, O_RDWR)
      doAssert inherited >= 0, "cannot open " & path & " for the control"
      try:
        check not hasCloseOnExec(inherited)
      finally:
        discard posix.close(inherited)
    finally:
      removeDir(dir)

  test "a spawned process does not inherit the device":
    when defined(linux):
      let dir = getTempDir() / ("repro-tpm-inherit-" & $getCurrentProcessId())
      removeDir(dir)
      createDir(dir)
      let path = dir / "tpm-device-stand-in"
      writeFile(path, "")
      try:
        let before = openDescriptors()
        let transport = newTpm2CharDeviceTransport(path)
        try:
          var opened: seq[cint] = @[]
          for fd in openDescriptors():
            if fd notin before: opened.add fd
          check opened.len == 1
          let fd = opened[0]

          # A real child, spawned while the transport is open, asked
          # what that descriptor number names for IT. The comparison is
          # against the path rather than against "is it open", because
          # a descriptor the child closed for its own reasons may be
          # reused by the spawn helper's own pipes — and a pipe at that
          # number is still not the device.
          let (output, status) = execCmdEx(
            "readlink /proc/self/fd/" & $fd & " 2>/dev/null || true")
          check status == 0
          check output.strip() != path
        finally:
          transport.transportClose()
      finally:
        removeDir(dir)
    else:
      # The device transport is a POSIX interface and this case reads
      # the child's descriptors through `/proc`, so it says nothing
      # anywhere else. Case 1 covers the flag on every POSIX host.
      check true
