## M58 gate: `integration_configurable_system_incremental_refinalize`.
##
## Normative description:
##
##   Adds an override to a finalized context, verifies only the
##   dirty closure resolves, and verifies a configurable whose
##   recomputed value is byte-identical does not propagate dirtiness
##   further. The full-resolve result matches the incremental result.

import std/[unittest]
import repro_dsl_stdlib/configurables

suite "M58 incremental refinalize":

  test "withOverrides re-resolves only the dirty closure":
    var portHandle, hostHandle, urlHandle, replicasHandle: Configurable[string]
    var rawPort: Configurable[int]
    var rawReplicas: Configurable[int]
    let original = evalConfig:
      let port = configurable 8080
      let host = configurable "localhost"
      let replicas = configurable 1
      let url = "http://" & host & ":" & $port
      rawPort = port
      rawReplicas = replicas
      hostHandle = host
      portHandle = $port
      urlHandle = url
      replicasHandle = $replicas

    check original.read(urlHandle) == "http://localhost:8080"

    # Change one configurable; verify only the dirty closure re-evaluates.
    let refined = withOverrides(original):
      rawPort.override 9000

    check refined.read(urlHandle) == "http://localhost:9000"
    # `replicas` and its derived stringified configurable should NOT
    # have been recomputed.
    check refined.refinalizeStats.visited > 0
    check refined.refinalizeStats.recomputed > 0
    # Sanity: the replicas chain is OFF the dirty path; the visited
    # count must be strictly less than the total node count.
    check refined.refinalizeStats.visited < original.nodes.len

  test "byte-identical recomputed value does not propagate":
    var rawPort: Configurable[int]
    var portStrHandle: Configurable[string]
    var doubledHandle: Configurable[int]
    let original = evalConfig:
      let port = configurable 8080
      let doubled = port * 2
      let portStr = $port
      rawPort = port
      portStrHandle = portStr
      doubledHandle = doubled

    # Refinalize with an override that resolves to the SAME value (8080).
    # The port node is recomputed once, sees its value unchanged, and
    # marks itself as a cutoff so the downstream `doubled` and
    # `portStr` nodes are NOT recomputed.
    let refined = withOverrides(original):
      rawPort.override 8080

    check refined.refinalizeStats.cutoffs >= 1
    # Downstream values are still correct.
    check refined.read(portStrHandle) == "8080"
    check refined.read(doubledHandle) == 16160

  test "incremental result matches full-resolve result":
    var rawPort: Configurable[int]
    var rawHost: Configurable[string]
    var urlHandle: Configurable[string]
    let original = evalConfig:
      let port = configurable 8080
      let host = configurable "localhost"
      let url = "http://" & host & ":" & $port
      rawPort = port
      rawHost = host
      urlHandle = url

    let incremental = withOverrides(original):
      rawHost.override "example.com"
      rawPort.override 9000

    let fullResolve = evalConfig:
      let port = configurable 8080
      let host = configurable "localhost"
      let url = "http://" & host & ":" & $port
      port.override 9000
      host.override "example.com"
      rawPort = port
      rawHost = host
      urlHandle = url

    check incremental.read(urlHandle) == fullResolve.read(urlHandle)
    check incremental.read(urlHandle) == "http://example.com:9000"
