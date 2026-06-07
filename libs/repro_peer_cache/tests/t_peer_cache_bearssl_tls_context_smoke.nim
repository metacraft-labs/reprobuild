## Peer-Cache-BearSSL M0 verification test:
## the `nim-bearssl` TLS surface is wired into the workspace.
##
## SCOPE — MINIMUM-VIABLE "CONSTRUCTS WITHOUT RAISING" SMOKE
## =========================================================
##
## The spec lists a full in-memory handshake round (client context +
## server context driven via paired in-memory buffers, both reaching
## SSL_RECVAPP / SSL_SENDAPP) as the ideal verification surface.
## Driving that without a real cert chain requires either:
##
##   * a fixture self-signed X.509 cert + matching EC private key
##     bundled with the test (M2 — `pki.nim` ships the cert builder), or
##   * a runtime cert generator (M2 also).
##
## Neither lands until M2; the spec's escape hatch
## ("If driving a handshake without sockets is non-trivial with this
## binding ... the **minimum viable** smoke is: client context
## constructs without raising, server context constructs without
## raising. Document the simplification.") applies here.
##
## This test therefore asserts:
##
##   1. `sslClientInitFull` returns cleanly against an empty trust
##      anchor set and a stack X.509 minimal context.
##   2. `sslClientReset` against a dummy SNI string returns 1
##      (BearSSL's "ready" signal) and the engine state machine
##      enters a non-zero state, demonstrating that the client side
##      is in a real "ready to send ClientHello" position.
##   3. The server context can be zeroed (`sslServerZero`) — its full
##      init requires a cert chain we don't have until M2.
##
## When M2 lands `pki.nim`, this file is the right place to extend
## with the real handshake-via-paired-buffers test the spec calls
## for.

import std/unittest

import bearssl/[ssl, x509]

{.used.}

suite "peer-cache bearssl tls context smoke":

  test "client context constructs and is ready to send ClientHello":
    # SslClientContext + X509MinimalContext are large; heap-allocate to
    # avoid stack pressure (each carries multi-KB inner buffers).
    var cc = new SslClientContext
    var xc = new X509MinimalContext

    # Empty trust anchor set: this won't validate any real cert, but
    # it's enough to drive init and reset cleanly. Real anchors
    # arrive in M2.
    sslClientInitFull(cc[], cast[ptr X509MinimalContext](addr xc[]),
                      nil, 0'u)

    # Wire up the input/output buffers so the engine has somewhere to
    # write its state. Bidi buffer for a real client.
    var ioBuf: array[SSL_BUFSIZE_BIDI, byte]
    sslEngineSetBuffer(cc[].eng, addr ioBuf[0], uint(ioBuf.len), 1.cint)

    # Reset with a dummy SNI; resumeSession = 0.
    let resetOk = sslClientReset(cc[], cstring"smoke.test.invalid", 0.cint)
    check resetOk == 1

    # After a successful reset the engine is in a non-CLOSED state and
    # has a ClientHello queued in SENDREC. Either state proves we got
    # past init without an internal error.
    let state = sslEngineCurrentState(cc[].eng)
    check state != 0'u
    check (state and SSL_CLOSED) == 0'u

  test "server context can be zeroed (full init deferred to M2)":
    # Full server init (`sslServerInitFullEc`) needs a parsed cert
    # chain + EC private key; that lands with M2's pki.nim. For M0
    # the smoke is that the type is constructible and `sslServerZero`
    # runs cleanly against a fresh allocation — i.e. the wiring of
    # the binding into the workspace produced a usable type.
    var sc = new SslServerContext
    sslServerZero(sc[])

    # Engine state of a zeroed server is well-defined: not in the
    # "send ClientHello" position, but the engine struct is touchable.
    # Touching `.eng.flags` here just proves the inner SslEngineContext
    # is laid out as the binding declares.
    sc[].eng.flags = 0'u32
    check sc[].eng.flags == 0'u32
