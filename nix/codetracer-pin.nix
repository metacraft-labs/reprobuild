# The CodeTracer source reprobuild consumes, and the codetracer-trace-format-nim
# source that goes with it, read from the organisation's single CodeTracer pin.
#
# `pins` is the parsed pin set of metacraft-labs/metacraft-github-actions
# (`pins/codetracer.json`, read through that repository's flake output `pins`
# or `import "<tree>/pins"`). Reprobuild keeps no CodeTracer revision of its
# own; it reads this one.
#
# Everything here is a pure, locked fetch, so it evaluates in a flake's pure
# mode and fetches nothing until a source is actually forced:
#
#   * CodeTracer is fetched by the pin's `rev` AND `narHash`, as a source tree
#     only. Its flake is never evaluated: it drags in the Electron, frontend
#     and db-backend toolchains, none of which reprobuild builds.
#   * The trace-format source is the revision that CodeTracer revision's own
#     `repro.lock` names for codetracer-trace-format-nim -- the one it was
#     solved and compiled against. The lock of the program being built governs
#     the revisions of everything it depends on, so CodeTracer's lock, not a
#     second revision recorded here, decides which trace-format source goes
#     with it. It is derived, never written down here, so it cannot drift from
#     the CodeTracer pin. `repro.lock` records a git commit
#     (`integrity = "git-sha1:<rev>"`) and no NAR hash, so this fetch is locked
#     by `rev` alone, which is the same integrity the lock itself carries.
#
# `traceFormatOf` is exposed so the same derivation can be applied to a
# CodeTracer tree that is NOT the pin (a `codetracer-src` override of a local
# checkout) and to the pin a published reprobuild commit locked
# (`nixpkgs-package-src-sync`).
let
  fail = msg: throw "reprobuild codetracer pin: ${msg}";

  validPin =
    pin:
    if pin.schema or null != 1 then
      fail "pins/codetracer.json has schema ${toString (pin.schema or "<none>")}; this reader understands schema 1 only"
    else if pin.tool or null != "codetracer" then
      fail "pins/codetracer.json names tool `${toString (pin.tool or "<none>")}`, expected `codetracer`"
    else if builtins.match "[0-9a-f]{40}" (pin.rev or "") == null then
      fail "pins/codetracer.json `rev` is `${toString (pin.rev or "<none>")}`, not a 40-hex commit id"
    else if !(pin ? narHash) then
      fail "pins/codetracer.json carries no `narHash`, so the fetch would not be locked"
    else
      pin;

  # The `repro.lock` entry for codetracer-trace-format-nim in a CodeTracer tree.
  # A tree with no lock, no such entry, more than one, or no `revision` is an
  # error: falling back to anything would build CodeTracer against a
  # trace-format it was not solved against.
  traceFormatEntryOf =
    codetracer:
    let
      what = "CodeTracer ${codetracer.rev or "(a tree with no rev: an override of a working tree)"}";
      lockPath = "${codetracer}/repro.lock";
      # repro.lock is TOML (reprobuild.solved-graph-lock v2/v3); the source
      # deps sit in the `[lock]` table's `deps` array.
      lock = builtins.fromTOML (builtins.readFile lockPath);
      # The locking repository's own entry (`self = "true"`, or `path = "."`
      # in older locks) is never a dependency of it.
      named = builtins.filter (
        dep:
        (dep.name or null) == "codetracer-trace-format-nim"
        && (dep.self or "") != "true"
        && (dep.path or "") != "."
      ) (lock.lock.deps or [ ]);
      entry = builtins.head named;
      parsed = builtins.match "https://github.com/([^/]+)/([^/]+)" (entry.url or "");
    in
    if !(builtins.pathExists lockPath) then
      fail "${what} has no repro.lock, so the trace-format revision it was built against is unknown"
    else if builtins.length named != 1 then
      fail "${what} repro.lock has ${toString (builtins.length named)} `deps` entries named codetracer-trace-format-nim, expected exactly 1"
    else if builtins.match "[0-9a-f]{40}" (entry.revision or "") == null then
      fail "${what} repro.lock's codetracer-trace-format-nim entry has no 40-hex `revision`"
    else if parsed == null then
      fail "${what} repro.lock's codetracer-trace-format-nim entry has url `${entry.url or ""}`, which is not a https://github.com/<owner>/<repo> url"
    else
      {
        owner = builtins.elemAt parsed 0;
        repo = builtins.elemAt parsed 1;
        rev = entry.revision;
      };

  traceFormatOf =
    codetracer:
    let
      entry = traceFormatEntryOf codetracer;
    in
    builtins.fetchTree {
      type = "github";
      inherit (entry) owner repo rev;
    };
in
pins:
let
  pin = validPin pins.codetracer;
  codetracer = builtins.fetchTree {
    type = "github";
    inherit (pin)
      owner
      repo
      rev
      narHash
      ;
  };
in
{
  inherit
    pin
    codetracer
    traceFormatEntryOf
    traceFormatOf
    ;
  traceFormat = traceFormatOf codetracer;
}
