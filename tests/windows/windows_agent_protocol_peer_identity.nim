## The Windows transport of the ReproOS agent protocol refuses every peer
## that is not the host's own user (spec
## `ReproOS-Agent-Integration-Protocol.md` §"The Windows transport",
## "Validation").
##
## Real named pipes, real tokens and a real second local account; nothing
## is mocked. The host and its clients share this process, which is
## sound because identity on a pipe is bound when the client opens it:
## every foreign client below opens its pipe under another token (the
## anonymous token, or the second account's logon) on this thread and
## reverts before the dispatcher runs again.
##
## Each refusal is shown against a positive control on the same server,
## so a host that answers nobody cannot pass. Where the DACL alone would
## refuse a peer, the case is run twice: once with the default owner-only
## DACL (the open is denied), and once on a host whose DACL admits that
## peer (`pipeSecurity`), where the identity check must refuse it on its
## own.
##
## Case (c) creates a temporary local account, which needs a member of
## Administrators. It fails, never skips, when the job cannot.

when not defined(windows):
  {.error: "windows_agent_protocol_peer_identity is a Windows gate".}

import std/[asyncdispatch, os, strutils, sysrand, unittest, widestrs]
import std/winlean

import repro_test_support/reasoned_skip

import cbor
import repro_agent_protocol
import repro_agent_protocol/[named_pipe, transport]

# --- Win32 used only by the test -------------------------------------

proc GetCurrentThread(): Handle {.stdcall, dynlib: "kernel32", importc.}
proc ImpersonateAnonymousToken(thread: Handle): WINBOOL {.
  stdcall, dynlib: "advapi32", importc.}
proc ImpersonateLoggedOnUser(token: Handle): WINBOOL {.
  stdcall, dynlib: "advapi32", importc.}
proc RevertToSelf(): WINBOOL {.stdcall, dynlib: "advapi32", importc.}
proc LogonUserW(user, domain, password: WideCString; logonType,
                provider: int32; token: ptr Handle): WINBOOL {.
  stdcall, dynlib: "advapi32", importc.}

type UserInfo1 {.pure.} = object
  name, password: WideCString
  passwordAge, priv: int32
  homeDir, comment: WideCString
  flags: int32
  scriptPath: WideCString

proc NetUserAdd(server: WideCString; level: int32; buf: pointer;
                parmErr: ptr int32): int32 {.
  stdcall, dynlib: "netapi32", importc.}
proc NetUserDel(server, user: WideCString): int32 {.
  stdcall, dynlib: "netapi32", importc.}

const
  ERROR_ACCESS_DENIED = 5'i32
  LOGON32_LOGON_NETWORK = 3'i32
  LOGON32_PROVIDER_DEFAULT = 0'i32
  USER_PRIV_USER = 1'i32
  UF_SCRIPT = 0x0001'i32
  UF_DONT_EXPIRE_PASSWD = 0x10000'i32

# --- Helpers ---------------------------------------------------------

type DirBackend = ref object of Backend

let root = getTempDir() / "rap-win-" & $getCurrentProcessId()
removeDir(root)

proc helloFrame(): seq[byte] =
  encodeDeterministic(cMap([tp("kind", cText("hello")),
    tp("protocol", cUInt(1)),
    tp("families", cArray([cText("checkout.v1")]))]))

proc answered(c: HostClient): bool =
  ## Whether the host answers this client's hello at all. A refused peer
  ## is closed without a response.
  let r = waitFor c.request(helloFrame())
  c.close()
  r.len > 0 and decodeItem(r).field("outcome").text == "ok"

proc ownClientAnswered(path: string): bool =
  answered(waitFor connectHost(path))

proc openAs(token: Handle; anonymous: bool; path: string): PipeStream =
  ## Open `path` on this thread under another identity, then revert.
  if anonymous:
    doAssert ImpersonateAnonymousToken(GetCurrentThread()) != 0,
      "ImpersonateAnonymousToken: " & osErrorMsg(osLastError())
  else:
    doAssert ImpersonateLoggedOnUser(token) != 0,
      "ImpersonateLoggedOnUser: " & osErrorMsg(osLastError())
  try:
    result = openPipeNow(path)
  finally:
    doAssert RevertToSelf() != 0, "RevertToSelf failed"

proc deniedOpen(token: Handle; anonymous: bool; path: string): bool =
  try:
    let p = openAs(token, anonymous, path)
    newHostClient(p).close()
    false
  except OSError as e:
    e.errorCode == ERROR_ACCESS_DENIED

proc hex(n: int): string =
  for b in urandom(n): result.add toHex(b, 2)

proc server(name: string; sddl = ""; consentPeer: ConsentPeerCheck = nil):
    HostServer =
  let h = newHost(DirBackend(), root / name / "workspaces")
  startServer(h, root / name / "run", consentPeer = consentPeer,
              pipeSecurity = sddl)

let ownSid = currentUserSid()
const AnonymousLogon = "AN" ## SDDL alias of S-1-5-7
const Everyone = "WD"

proc widened(alias: string): string =
  ## The owner-only DACL plus an allow for `alias`, and an Untrusted
  ## mandatory label. The anonymous token runs at Untrusted integrity, and
  ## an object with no label counts as Medium with no-write-up, so the
  ## label is what lets the DACL's allow actually admit that token
  ## (https://learn.microsoft.com/en-us/windows/win32/secauthz/mandatory-integrity-control).
  ownerOnlySddl(ownSid) & "(A;;GA;;;" & alias & ")S:(ML;;NW;;;S-1-16-0)"

proc refuseSecondUser(token: Handle) =
  ## Case (c) once the account exists and is logged on.
  let strict = server("user-dacl")
  check deniedOpen(token, anonymous = false, strict.providerPath)
  check deniedOpen(token, anonymous = false, strict.consentPath)
  check ownClientAnswered(strict.providerPath)
  strict.stop()
  let open = server("user-sid", sddl = widened(Everyone))
  let p = openAs(token, anonymous = false, open.providerPath)
  check not answered(newHostClient(p))
  let q = openAs(token, anonymous = false, open.consentPath)
  check not answered(newHostClient(q))
  check ownClientAnswered(open.providerPath)
  open.stop()

# --- Cases -----------------------------------------------------------

suite "Windows transport — only the host's user is a peer":

  test "the host's own user is served on both channels (positive control)":
    var seenPids: seq[int]
    let s = server("own", consentPeer = proc (pid: int): bool {.gcsafe.} =
      {.cast(gcsafe).}: seenPids.add pid
      true)
    check s.providerPath.startsWith("\\\\.\\pipe\\reproos-agent-" & ownSid & "-")
    check s.providerPath.endsWith("-provider")
    check s.consentPath == consentPathBeside(s.providerPath)
    check ownClientAnswered(s.providerPath)
    check ownClientAnswered(s.consentPath)
    # The consent policy saw this process's (advisory) pid.
    check seenPids == @[getCurrentProcessId()]
    s.stop()

  test "(a) wrong peer: the anonymous token is refused by the DACL and by the identity check":
    let strict = server("anon-dacl")
    check deniedOpen(Handle(0), anonymous = true, strict.providerPath)
    check deniedOpen(Handle(0), anonymous = true, strict.consentPath)
    check ownClientAnswered(strict.providerPath)
    strict.stop()
    # A host whose DACL admits ANONYMOUS LOGON still refuses it.
    let open = server("anon-sid", sddl = widened(AnonymousLogon))
    let p = openAs(Handle(0), anonymous = true, open.providerPath)
    check not answered(newHostClient(p))
    check ownClientAnswered(open.providerPath)
    open.stop()

  test "(b) a client that grants only anonymous impersonation is refused":
    let s = server("anon-level")
    check not answered(waitFor connectHost(s.providerPath, ciAnonymous))
    check not answered(waitFor connectHost(s.consentPath, ciAnonymous))
    check ownClientAnswered(s.providerPath)
    s.stop()

  test "(d) a squatter on either pipe name stops the host from starting":
    let nonce = hex(16).toLowerAscii
    let base = "\\\\.\\pipe\\reproos-agent-" & ownSid & "-" & nonce
    for (squatted, other) in [("-provider", "-consent"),
                              ("-consent", "-provider")]:
      checkpoint squatted
      let squatter = listenPipe(base & squatted, widened(Everyone))
      let h = newHost(DirBackend(), root / "squat" / "workspaces")
      expect OSError:
        discard startServer(h, root / "squat" / "run", pipeNonce = nonce)
      # The host left nothing listening under the other name either.
      expect OSError:
        discard openPipeNow(base & other)
      squatter.close()
    # With the squatter gone the same names serve (control).
    let h = newHost(DirBackend(), root / "squat" / "workspaces")
    let s = startServer(h, root / "squat" / "run", pipeNonce = nonce)
    check ownClientAnswered(s.providerPath)
    s.stop()

  test "(e) the SMB route to the host's pipes is refused":
    let s = server("remote")
    let local = s.providerPath
    let remote = "\\\\localhost\\pipe\\" &
      local["\\\\.\\pipe\\".len .. ^1]
    var refused = false
    try:
      let p = openPipeNow(remote)
      refused = not answered(newHostClient(p))
    except OSError as e:
      checkpoint "remote open: " & e.msg
      refused = true
    check refused
    # Control: the same route reaches a pipe that does not reject remote
    # clients, so the refusal above is the flag's and not an absent SMB
    # server's.
    let ctlName = "rap-ctl-" & hex(8)
    let ctl = createNamedPipe(newWideCString("\\\\.\\pipe\\" & ctlName),
      PIPE_ACCESS_DUPLEX, 0, 1, 4096, 4096, 0, nil)
    require ctl != INVALID_HANDLE_VALUE
    defer: discard closeHandle(ctl)
    let viaSmb = createFileW(newWideCString("\\\\localhost\\pipe\\" & ctlName),
      GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0)
    checkpoint "control open via SMB: " &
      (if viaSmb == INVALID_HANDLE_VALUE: osErrorMsg(osLastError()) else: "ok")
    check viaSmb != INVALID_HANDLE_VALUE
    if viaSmb != INVALID_HANDLE_VALUE:
      discard closeHandle(viaSmb)
    check ownClientAnswered(local)
    s.stop()

  # Last, so a job identity that cannot create accounts fails this case
  # without hiding the others' verdicts.
  test "(c) a different local user is refused by the DACL and by the identity check":
    let user = "rap" & hex(4)
    let password = "Rp!" & hex(12) & "a9Z"
    var info = UserInfo1(name: newWideCString(user),
      password: newWideCString(password), priv: USER_PRIV_USER,
      flags: UF_SCRIPT or UF_DONT_EXPIRE_PASSWD)
    var parmErr: int32
    let added = NetUserAdd(nil, 1, addr info, addr parmErr)
    checkpoint "NetUserAdd(" & user & ") = " & $added & " (5 = access denied: " &
      "the job identity is not an Administrator; this case needs one)"
    if added == ERROR_ACCESS_DENIED:
      # The case's precondition, not its subject: only an Administrator may
      # create the second local account the refusal is checked against. A
      # job identity that is not one cannot run the case, and says so; any
      # other NetUserAdd failure is still a failure.
      skip("conditions not met: creating a second local user needs an " &
        "Administrator job identity (NetUserAdd = 5, access denied)")
    else:
      check added == 0
    if added == 0:
      var token: Handle
      let logged = LogonUserW(newWideCString(user), newWideCString("."),
        newWideCString(password), LOGON32_LOGON_NETWORK,
        LOGON32_PROVIDER_DEFAULT, addr token)
      checkpoint "LogonUserW: " &
        (if logged == 0: osErrorMsg(osLastError()) else: "ok")
      check logged != 0
      if logged != 0:
        try:
          refuseSecondUser(token)
        finally:
          discard closeHandle(token)
      check NetUserDel(nil, newWideCString(user)) == 0

removeDir(root)
