## How a request to the shared Nix helper carries the requesting process's
## Nix configuration (`repro_core/nix_configuration_env`).
##
## The helper outlives the process that starts it and serves every client of
## the user, so it must run each request's `nix` with that request's
## configuration -- its credential included -- rather than its own (reprobuild-pm
## issue 2026-11-10-repro-daemon-nix-fetch-gets-http-401-on-a-persistent-macos-runner).
## The helper's half is pinned by
## `tests/unit/test_nix_daemon_runs_nix_with_the_requesting_clients_configuration.py`;
## this file pins the client's half: what a request names, that a variable
## this process does not set is sent as `null` rather than left out, and the
## peer-user check made before a request is sent.
##
## Real process environment and a real socket pair; no mocks.

import std/[json, os, strtabs, unittest]

when defined(posix):
  import std/[nativesockets, posix]

import repro_core/nix_configuration_env

template withNixEnv(values: openArray[(string, string)]; body: untyped) =
  ## Run `body` with exactly `values` set among the Nix configuration
  ## variables (the rest unset), restoring the process's own afterwards.
  block:
    var saved: seq[(string, string, bool)]
    for name in NixConfigurationEnvNames:
      saved.add((name, getEnv(name), existsEnv(name)))
      delEnv(name)
    for (name, value) in values:
      putEnv(name, value)
    try:
      body
    finally:
      for (name, value, present) in saved:
        if present: putEnv(name, value) else: delEnv(name)

suite "the Nix configuration a helper request carries":
  test "every name is sent, a set value as a string and an unset one as null":
    withNixEnv({"NIX_CONFIG": "!include /job/nix-access-tokens.conf",
                "XDG_CONFIG_HOME": ""}):
      let env = nixHelperRequestEnvironment()
      check env.kind == JObject
      check env.len == NixConfigurationEnvNames.len
      check env["NIX_CONFIG"].getStr() ==
        "!include /job/nix-access-tokens.conf"
      # An empty value is a value: it is not the same as unset to Nix.
      check env["XDG_CONFIG_HOME"].kind == JString
      check env["XDG_CONFIG_HOME"].getStr() == ""
      # Unset is sent as null, so the helper unsets it instead of falling back
      # to its own value.
      for name in ["NIX_USER_CONF_FILES", "NIX_CONF_DIR", "XDG_CONFIG_DIRS"]:
        check env[name].kind == JNull

  test "the request keeps its members and gains the configuration":
    withNixEnv({"NIX_CONFIG": "access-tokens = github.com=one"}):
      let sent = parseJson(withNixHelperRequestEnvironment(
        """{"action":"resolve","selector":"nixpkgs#gcc","workspaceRoot":"/w"}"""))
      check sent["action"].getStr() == "resolve"
      check sent["selector"].getStr() == "nixpkgs#gcc"
      check sent["workspaceRoot"].getStr() == "/w"
      check sent[NixHelperRequestEnvironmentKey]["NIX_CONFIG"].getStr() ==
        "access-tokens = github.com=one"

  test "a second request carries the configuration current when it is sent":
    var first, second: JsonNode
    withNixEnv({"NIX_CONFIG": "!include /job-one/tokens.conf"}):
      first = parseJson(withNixHelperRequestEnvironment("""{"action":"resolve"}"""))
    withNixEnv({"NIX_CONFIG": "!include /job-two/tokens.conf"}):
      second = parseJson(withNixHelperRequestEnvironment("""{"action":"resolve"}"""))
    check first[NixHelperRequestEnvironmentKey]["NIX_CONFIG"].getStr() ==
      "!include /job-one/tokens.conf"
    check second[NixHelperRequestEnvironmentKey]["NIX_CONFIG"].getStr() ==
      "!include /job-two/tokens.conf"

  test "a configuration already in the request is replaced, not merged":
    withNixEnv({"NIX_CONFIG": "current"}):
      let sent = parseJson(withNixHelperRequestEnvironment(
        """{"action":"resolve","nixEnvironment":{"NIX_CONF_DIR":"/old"}}"""))
      check sent[NixHelperRequestEnvironmentKey]["NIX_CONFIG"].getStr() ==
        "current"
      check sent[NixHelperRequestEnvironmentKey]["NIX_CONF_DIR"].kind == JNull

  test "a request that is not a JSON object is refused":
    expect ValueError:
      discard withNixHelperRequestEnvironment("not json")
    expect ValueError:
      discard withNixHelperRequestEnvironment("[1, 2]")

  test "the helper is started without the starter's Nix configuration":
    withNixEnv({"NIX_CONFIG": "access-tokens = github.com=starter",
                "NIX_USER_CONF_FILES": "/starter.conf"}):
      let env = environmentWithoutNixConfiguration()
      for name in NixConfigurationEnvNames:
        check not env.hasKey(name)
      # Everything else is kept: the helper still needs PATH to find nix.
      check env.hasKey("PATH")
      check env["PATH"] == getEnv("PATH")

when defined(posix):
  suite "the helper's peer user":
    test "a peer running as this user is accepted":
      var fds: array[2, cint]
      check socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0
      defer:
        discard close(fds[0])
        discard close(fds[1])
      check nixHelperPeerIsThisUser(SocketHandle(fds[0]))

    test "a descriptor whose peer cannot be determined is refused":
      # Not a socket: the kernel reports no peer, which must read as "not
      # this user" rather than as a pass.
      var pipeFds: array[2, cint]
      check pipe(pipeFds) == 0
      defer:
        discard close(pipeFds[0])
        discard close(pipeFds[1])
      check not nixHelperPeerIsThisUser(SocketHandle(pipeFds[0]))
