## A dynamic graph fragment's `create-action` record carries a dependency
## policy, and a cacheable record without one is refused.
##
## A created action that is `cacheable` is served from the action cache when
## its key matches. The key of a monitored action covers what the process
## was seen to read; without a policy the record could only be keyed on what
## it declares, the declared-only shape `repro_core/dependency_gathering.nim`
## forbids. So the record names its policy in the vocabulary of the DSL's
## static edges (`automaticMonitor`, or `makeDepfile` with its depfiles), the
## engine lowers it onto the action, and the policy is part of the key.
##
## No mocks: every case decodes a real payload through the engine's own
## `parseCreateActionRecord`. The engine-level behaviour (the created action
## monitored, replayed and rekeyed) is
## `tests/integration/t_engine_created_action_replays_and_rekeys.nim`.
##
## Falsifiers:
## * drop the `elif cacheable:` refusal in `parseCreateActionRecord` and the
##   "refused" cases go red;
## * drop `keyedOnCreatedActionPolicy` from the record's fingerprint and the
##   "key moves" cases go red;
## * stop passing `dependencyPolicy` to `action()` and the depfile case reads
##   back the monitor.
##
## A record also carries `envPassthrough`, as a declared edge does: the names
## of variables whose value is the host's (a per-test compile created from a
## nim compile edge carries that edge's temp-directory names). The names
## reach the action and its key; a malformed name is refused. Falsifier:
## stop passing `envPassthrough` to `action()` and those cases go red.
##
## And an `actionCachePolicy` (`timestamp`, the default; `hybrid`;
## `checksum`), as a declared edge's: a per-test binary's run is `hybrid`, so
## a binary rebuilt byte-identical is a hit. Like a declared edge's, the
## policy is not in the key (a lookup is served only records made under the
## same policy). Falsifier: stop passing it to `action()` and the `hybrid`
## case reads back `ffpTimestamp`.

import std/[json, strutils, unittest]

import repro_build_engine {.all.}
import repro_core
import repro_core/input_check_policy
from repro_depfile import MakeDepfileFormatName

proc decode(node: JsonNode): BuildAction =
  parseCreateActionRecord($node, "consumer.rbdyn", 2,
    lockIdentityOutsideSolvedGraph())

proc record(policy: JsonNode; cacheable = true): JsonNode =
  result = %*{
    "id": "per-test/alpha",
    "argv": ["/work/tests-bin", "--entrypoint=tests", "--run-exact=alpha"],
    "cwd": "/work",
    "inputs": ["/work/tests-bin"],
    "cacheable": cacheable
  }
  if policy != nil:
    result["dependencyPolicy"] = policy

proc refusal(node: JsonNode): string =
  ## The message of the error decoding `node` raises, or "" when it decodes.
  try:
    discard decode(node)
  except BuildEngineError as err:
    return err.msg
  ""

let monitor = %*{"kind": "automaticMonitor"}
let depfile = %*{"kind": "makeDepfile", "depfiles": ["alpha.d"]}

suite "create-action record: dependency policy is parsed":

  test "automaticMonitor lowers to the monitored policy":
    let created = decode(record(monitor))
    check created.cacheable
    check created.dependencyPolicy.kind == dgAutomaticMonitor
    check created.dependencyPolicy.kind in MonitorPolicyKinds
    check created.dependencyPolicy.recognizedReports.len == 0

  test "makeDepfile lowers to a make-depfile report per path":
    let created = decode(record(%*{"kind": "makeDepfile",
      "depfiles": ["alpha.d", "out/*.d"]}))
    check created.dependencyPolicy.kind == dgRecognizedFormat
    require created.dependencyPolicy.recognizedReports.len == 1
    let report = created.dependencyPolicy.recognizedReports[0]
    check $report.formatName == MakeDepfileFormatName
    check report.outputs.len == 2
    check report.outputs[0].path == "alpha.d"
    check report.outputs[1].path == "out/*.d"
    check not report.outputs[0].required

  test "a record that is not cacheable keeps the monitored default":
    let created = decode(record(nil, cacheable = false))
    check not created.cacheable
    check created.dependencyPolicy.kind == dgAutomaticMonitor

  test "a policy on a record that is not cacheable is honoured too":
    let created = decode(record(depfile, cacheable = false))
    check created.dependencyPolicy.kind == dgRecognizedFormat

suite "create-action record: a cacheable record without a policy is refused":

  test "the refusal names the record, where it is, and the remedy":
    # Negative control for the engine test: the same record the integration
    # test builds, without its policy.
    let message = refusal(record(nil))
    checkpoint(message)
    check message.len > 0
    check "consumer.rbdyn:2" in message
    check "'per-test/alpha'" in message
    check "cacheable but declares no 'dependencyPolicy'" in message
    check "automaticMonitor" in message

  test "the same record with a policy is accepted":
    check refusal(record(monitor)) == ""
    check refusal(record(depfile)) == ""

  test "malformed policies are refused, not ignored":
    for bad in [
        %*"automaticMonitor",
        %*{"depfiles": ["a.d"]},
        %*{"kind": 3},
        %*{"kind": "declaredOnly"},
        %*{"kind": ""},
        %*{"kind": "makeDepfile"},
        %*{"kind": "makeDepfile", "depfiles": []},
        %*{"kind": "makeDepfile", "depfiles": [""]},
        %*{"kind": "makeDepfile", "depfiles": "a.d"},
        %*{"kind": "makeDepfile", "depfile": ["a.d"]},
        %*{"kind": "automaticMonitor", "depfiles": ["a.d"]}]:
      let message = refusal(record(bad))
      checkpoint($bad & " -> " & message)
      check message.len > 0
      check "dependency" in message.toLowerAscii

  test "a malformed policy is refused on a record that is not cacheable":
    check refusal(record(%*{"kind": "declaredOnly"}, cacheable = false)).len > 0

suite "create-action record: the key moves with the policy":

  test "the same record and policy key the same":
    check decode(record(monitor)).weakFingerprint ==
      decode(record(monitor)).weakFingerprint
    check decode(record(depfile)).weakFingerprint ==
      decode(record(depfile)).weakFingerprint

  test "monitor and depfile key differently":
    check decode(record(monitor)).weakFingerprint !=
      decode(record(depfile)).weakFingerprint

  test "a different depfile list keys differently":
    check decode(record(depfile)).weakFingerprint !=
      decode(record(%*{"kind": "makeDepfile",
        "depfiles": ["beta.d"]})).weakFingerprint
    check decode(record(depfile)).weakFingerprint !=
      decode(record(%*{"kind": "makeDepfile",
        "depfiles": ["alpha.d", "beta.d"]})).weakFingerprint

  test "depfile lists are framed, not concatenated":
    check decode(record(%*{"kind": "makeDepfile",
        "depfiles": ["ab.d"]})).weakFingerprint !=
      decode(record(%*{"kind": "makeDepfile",
        "depfiles": ["a", "b.d"]})).weakFingerprint

  test "keyedOnCreatedActionPolicy moves the key":
    let seed = weakFingerprintFromText("seed")
    check keyedOnCreatedActionPolicy(seed, "automaticMonitor", []) != seed
    check keyedOnCreatedActionPolicy(seed, "automaticMonitor", []) !=
      keyedOnCreatedActionPolicy(seed, "makeDepfile", ["a.d"])

suite "create-action record: environment passthrough":

  test "the names reach the action, beside the declared environment":
    var node = record(monitor)
    node["env"] = %["PATH=/tools"]
    node["envPassthrough"] = %["TMPDIR", "TEMP"]
    let created = decode(node)
    check created.env == @["PATH=/tools"]
    check created.envPassthrough == @["TMPDIR", "TEMP"]
    check decode(record(monitor)).envPassthrough.len == 0

  test "the names key the action":
    var node = record(monitor)
    node["envPassthrough"] = %["TMPDIR"]
    check decode(node).weakFingerprint !=
      decode(record(monitor)).weakFingerprint
    var other = record(monitor)
    other["envPassthrough"] = %["TEMP"]
    check decode(node).weakFingerprint != decode(other).weakFingerprint
    check decode(node).weakFingerprint == decode(node).weakFingerprint

  test "a name that is not a variable name is refused":
    for bad in [%[""], %["TMPDIR=/tmp"], %[1], %"TMPDIR"]:
      var node = record(monitor)
      node["envPassthrough"] = bad
      let message = refusal(node)
      checkpoint($bad & " -> " & message)
      check "envPassthrough" in message

suite "create-action record: input-check policy":

  test "the policy reaches the action, timestamp by default":
    check decode(record(monitor)).actionCachePolicy == ffpTimestamp
    for (name, policy) in [("timestamp", ffpTimestamp),
        ("hybrid", ffpHybrid), ("checksum", ffpChecksum)]:
      var node = record(monitor)
      node["actionCachePolicy"] = %name
      check decode(node).actionCachePolicy == policy

  test "the policy is not in the key, as for a declared edge":
    var node = record(monitor)
    node["actionCachePolicy"] = %"hybrid"
    check decode(node).weakFingerprint ==
      decode(record(monitor)).weakFingerprint

  test "an unknown policy is refused":
    for bad in [%"content", %1]:
      var node = record(monitor)
      node["actionCachePolicy"] = bad
      let message = refusal(node)
      checkpoint($bad & " -> " & message)
      check "actionCachePolicy" in message
