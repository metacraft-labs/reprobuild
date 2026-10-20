## Run the whole local development double on one background thread
## (`Remix-Registry.md` §"Local development double").
##
## Zones are separated as components with their own directories and only
## the Boundary spool, the publish directory and loopback HTTP between them;
## they are not separated as hosts or VMs (threat-model deviation D1). The
## thread owns its own async dispatcher, so callers — tests, the CLI, a UI
## under development — use ordinary blocking HTTP against the two ports.

import std/[asyncdispatch, atomics, os]

import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

import ./boundary
import ./registrar
import ./edge

type
  DoubleArgs = object
    root: string
    privateKey: PrivateKeyBytes
    publicKey: PublicKeyBytes
    tickMs: int
    ratePerMinute: int
    extraReserved: seq[string]
    ports: ptr Channel[(int, int)]
    stop: ptr Atomic[bool]

  DoubleHandle* = object
    intakePort*, readPort*: int
    root*: string
    thread: ref Thread[DoubleArgs]
    ports: ptr Channel[(int, int)]
    stop: ptr Atomic[bool]

proc dirs*(root: string): RegistrarConfig =
  RegistrarConfig(dataDir: root / "interior" / "data",
    publishDir: root / "edge-read" / "published",
    spoolDir: root / "boundary" / "spool",
    captureDir: root / "evidence")

proc doubleMain(a: DoubleArgs) {.thread.} =
  {.cast(gcsafe).}:
    var cfg = dirs(a.root)
    cfg.ratePerMinute = a.ratePerMinute
    cfg.extraReserved = a.extraReserved
    let key = PeerKeypair(privateKey: a.privateKey, publicKey: a.publicKey)
    let reg = newRegistrar(cfg, key)
    let intake = newIntake(initSpool(cfg.spoolDir), "intake-0")
    let rf = newReadFront(cfg.publishDir)
    intake.start()
    rf.start()
    a.ports[].send((int(intake.port), int(rf.port)))
    var sinceTick = 0
    while not a.stop[].load:
      try:
        poll(5)
      except ValueError:
        sleep(5)                         # no pending operations
      sinceTick += 5
      if sinceTick >= a.tickMs:
        sinceTick = 0
        discard reg.tick()
    intake.close()
    rf.close()

proc startDouble*(root: string; logKey: PeerKeypair; tickMs = 20;
                  ratePerMinute = 0; extraReserved: seq[string] = @[]): DoubleHandle =
  result.root = root
  result.ports = cast[ptr Channel[(int, int)]](allocShared0(sizeof(Channel[(int, int)])))
  result.ports[].open()
  result.stop = cast[ptr Atomic[bool]](allocShared0(sizeof(Atomic[bool])))
  result.thread = new Thread[DoubleArgs]
  createThread(result.thread[], doubleMain, DoubleArgs(root: root,
    privateKey: logKey.privateKey, publicKey: logKey.publicKey,
    tickMs: tickMs, ratePerMinute: ratePerMinute, extraReserved: extraReserved,
    ports: result.ports, stop: result.stop))
  let (i, r) = result.ports[].recv()
  result.intakePort = i
  result.readPort = r

proc intakeBase*(h: DoubleHandle): string = "http://127.0.0.1:" & $h.intakePort
proc readBase*(h: DoubleHandle): string = "http://127.0.0.1:" & $h.readPort

proc stopDouble*(h: var DoubleHandle) =
  h.stop[].store(true)
  joinThread(h.thread[])
  h.ports[].close()
  deallocShared(h.ports)
  deallocShared(h.stop)
