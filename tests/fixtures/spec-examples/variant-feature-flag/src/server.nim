## Tiny HTTP server stand-in for the spec-example variant-feature-flag
## fixture. The actual server logic is irrelevant — the point is that
## the build graph shape changes with the `enableTLS` variant.

when defined(useTls):
  proc startServer*(port: int): bool =
    ## TLS-enabled placeholder. Real implementation would link openssl.
    echo "starting TLS server on port ", port
    true
else:
  proc startServer*(port: int): bool =
    ## Plain HTTP placeholder.
    echo "starting plain-HTTP server on port ", port
    true

when isMainModule:
  discard startServer(8080)
