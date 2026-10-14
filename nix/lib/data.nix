# `reprobuild.lib.readData` -- a plan-time data file read by Nix with the
# profile planner's row-selection semantics.
#
# A profile's `data:` section names TOML files of `[[package]]` (and
# `[[resource]]`) rows; `repro home plan` / `apply` / `export` read them after
# the profile compile (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
# §Declarative data files read at plan time). A rung-1 Nix module reads the
# same file with `builtins.fromTOML` and must select exactly the rows the
# profile does, and refuse exactly the files the planner refuses. The
# selection rule is the planner's ordinary one, restated here only because
# the Nix boundary requires it:
#
#   * a package row applies when its `activity` is enabled for the host --
#     `default`, plus the activities the host's `hosts:` entry names
#     (`enabledActivitiesFor`) -- and its `when` (built-in grammar) holds for
#     the target system and host;
#   * a package selected by several rows is one package; the row the
#     planner meets first supplies its metadata (`buildPlan`'s
#     de-duplication over activities in first-appearance order, see
#     `selectRows`);
#   * rows are `[[package]]` tables or, equivalently, an inline array of
#     inline tables (`builtins.fromTOML` cannot tell the two apart, and the
#     planner accepts both).
#
# The row schema is checked as `repro_home_intent/data_file.nim`
# (`parseDataFileRows`, `decodeRow`) checks it, with the same diagnostics
# where the shared fixtures pin them ("row N", "`key`", the reason).
#
# `[[resource]]` rows are REFUSED, never ignored (Core-Invariants.md
# §Unrecognised Input Is Rejected, Not Skipped). A resource row is a call of
# the profile's resource constructor; its schema, defaults and auto-address
# are the constructor's (`repro_profile/resource_rows`), and restating 13
# constructors in Nix would be a second implementation of each (spec P1/P6).
# Resources reach Nix through the export instead (`readIntent`), which
# carries them already built.
#
# Both implementations are tested against `tests/fixtures/data-files/`
# (`t_data_file_row_selection_fixtures` for the planner, `lib-tests` and
# `e2e_nix_reads_data_like_profile` for this file).
{ predicate, platforms }:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    elem
    filter
    foldl'
    genList
    isAttrs
    isList
    isString
    length
    elemAt
    match
    typeOf
    ;

  packageRowKeys = [
    "name"
    "activity"
    "when"
    "version"
    "binaries"
  ];
  rowTables = [
    "package"
    "resource"
  ];

  # TOML value kinds as data_file.nim prints them (`$TomlKind`).
  kindName =
    v:
    let
      t = typeOf v;
    in
    if t == "string" then
      "String"
    else if t == "int" then
      "Int"
    else if t == "float" then
      "Float"
    else if t == "bool" then
      "Bool"
    else if t == "list" then
      "Array"
    else if t == "set" then
      "Table"
    else
      t;

  # `raiseDataFile`: "data file <path>[ row N][ key `k`]: <reason>".
  diagnostic =
    file: row: key: reason:
    "data file ${file}"
    + (if row > 0 then " row ${toString row}" else "")
    + (if key != "" then " key `${key}`" else "")
    + ": ${reason}";

  # `packageNameProblem` / `activityNameProblem` in data_file.nim.
  packageNameProblem =
    name:
    if name == "" then
      "the package name is empty"
    else if match "[A-Za-z0-9._+-]+" name == null then
      "`${name}` contains a character outside the canonical package name set; a canonical package name uses letters, digits, `.`, `_`, `+` and `-`"
    else
      "";
  activityNameProblem =
    name:
    if name == "" then
      "the activity name is empty"
    else if match "[A-Za-z].*" name == null then
      "`${name}` must start with a letter"
    else if match "[A-Za-z0-9_]+" name == null then
      "`${name}` contains a character outside letters, digits and `_`; an activity name uses letters, digits and `_`"
    else
      "";

  # A row's `when`: non-empty and of the built-in grammar (`validateRowGuard`).
  guardProblem =
    source:
    if match "[[:space:]]*" source != null then
      "an empty predicate; omit the key for every host"
    else
      let
        v = predicate.validate source;
      in
      if v.ok then
        ""
      else if v.class == "unknown-identifier" then
        "`${source}` names '${v.identifier}', which is not a built-in predicate; data files accept only windows, macos, linux, bsd, wsl, x86_64, arm64, arm32 and host ==/!=/in, combined with and/or/not (a user-defined predicate has no evaluator outside the profile's Nim code)"
      else
        "`${source}` is not a valid predicate: ${v.message}";

  # Decode one `[[package]]` row (`decodeRow`). Returns the row or
  # `{ error; }`. Keys are visited in attribute order (Nix sorts them; the
  # Nim reader visits them in file order, so a row with two problems may be
  # reported by a different one of them -- it is refused either way).
  decodeRow =
    file: n: row:
    let
      err = key: reason: { error = diagnostic file n key reason; };
      keyProblem =
        key:
        let
          v = row.${key};
        in
        if !(elem key packageRowKeys) then
          err key "unknown key; a `[[package]]` row has ${concatStringsSep ", " packageRowKeys}"
        else if key == "binaries" then
          (
            if !isList v then
              err key "expected an array of strings, got ${kindName v}"
            else
              foldl' (
                acc: b:
                if acc != null then
                  acc
                else if !isString b then
                  err key "expected a string, got ${kindName b}"
                else if b == "" then
                  err key "a binary name is empty"
                else
                  null
              ) null v
          )
        else if !isString v then
          err key "expected a string, got ${kindName v}"
        else
          null;
      firstKeyProblem = foldl' (acc: key: if acc != null then acc else keyProblem key) null (
        attrNames row
      );
      name = row.name or "";
      activity = row.activity or "";
      nameProblem = packageNameProblem name;
      activityProblem = activityNameProblem activity;
      whenProblem = if row ? when then guardProblem row.when else "";
    in
    if firstKeyProblem != null then
      firstKeyProblem
    else if !(row ? name) then
      err "name" "required key missing"
    else if !(row ? activity) then
      err "activity" "required key missing"
    else if nameProblem != "" then
      err "name" nameProblem
    else if activityProblem != "" then
      err "activity" activityProblem
    else if row ? version && row.version == "" then
      err "version" "an empty version; omit the key for an unpinned reference"
    else if whenProblem != "" then
      err "when" whenProblem
    else
      {
        inherit name activity;
        when = row.when or null;
        version = row.version or "";
        binaries = row.binaries or [ ];
        row = n;
      };

  # Parse and validate a data file's text (`parseDataFileRows`). Returns
  # `{ rows; }` or `{ error; }`.
  parseRows =
    file: content:
    let
      root = builtins.fromTOML content;
      keys = attrNames root;
      badKey = filter (k: !(elem k rowTables)) keys;
      badShape = filter (k: !(isList root.${k} && builtins.all isAttrs root.${k})) keys;
      packages = root.package or [ ];
      resources = root.resource or [ ];
      decoded = genList (i: decodeRow file (i + 1) (elemAt packages i)) (length packages);
      firstError = foldl' (
        acc: r:
        if acc != null then
          acc
        else if r ? error then
          r
        else
          null
      ) null decoded;
    in
    if badKey != [ ] then
      {
        error =
          diagnostic file 0 (builtins.head badKey)
            "unknown top-level key; a data file holds `[[package]]` and `[[resource]]` rows only";
      }
    else if badShape != [ ] then
      {
        error =
          let
            k = builtins.head badShape;
          in
          diagnostic file 0 k "`${k}` must be an array of tables (`[[${k}]]`), got ${kindName root.${k}}";
      }
    # Package rows are checked before resource rows, as the planner does.
    else if firstError != null then
      firstError
    else if resources != [ ] then
      {
        error =
          diagnostic "${file} resource" 1 "kind"
            "readData does not read `[[resource]]` rows (this file has ${toString (length resources)}): a resource row is a call of the profile's resource constructor, whose defaults and address only Reprobuild computes. Read the profile's resources through `reprobuild.lib.readIntent`, which carries them expanded, or move them out of this file";
      }
    else
      { rows = decoded; };

  # Rows that apply on `host` / `system`, de-duplicated by package name,
  # sorted by name. Which row of a package selected several times supplies
  # its metadata (version, binaries, activity) is the planner's choice: the
  # expansion appends each row to its activity, creating activities in
  # first-row order (`mergeDataRows`), and `buildPlan` walks the activities
  # in that order and keeps a package's first occurrence. So rows are taken
  # activity by activity (activities in first-appearance order), in file
  # order within each -- not simply in file order. (In a profile that also
  # declares the activities in `home.nim`, the declaration order decides;
  # readData sees the data file alone.)
  selectRows =
    {
      rows,
      system,
      host,
      activities,
    }:
    let
      facts = platforms.factsFor system host;
      applies = r: elem r.activity activities && predicate.holds facts r.when;
      activityOrder = foldl' (acc: r: if elem r.activity acc then acc else acc ++ [ r.activity ]) [ ] rows;
      plannerOrder = builtins.concatMap (a: filter (r: r.activity == a) rows) activityOrder;
      chosen =
        foldl'
          (
            acc: r:
            if acc.seen ? ${r.name} then
              acc
            else
              {
                seen = acc.seen // {
                  ${r.name} = true;
                };
                list = acc.list ++ [ r ];
              }
          )
          {
            seen = { };
            list = [ ];
          }
          (filter applies plannerOrder);
    in
    builtins.sort (a: b: a.name < b.name) chosen.list;

  # Everything `readData` does, with failures as values (`{ error; }`) so
  # the tests can compare diagnostics.
  readDataResult =
    {
      path,
      system,
      host,
      hosts ? { },
      activities ? null,
      name ? baseNameOf (toString path),
    }:
    let
      parsed = parseRows name (builtins.readFile path);
      enabled = [ "default" ] ++ (if activities != null then activities else hosts.${host} or [ ]);
      selected = selectRows {
        inherit (parsed) rows;
        inherit system host;
        activities = enabled;
      };
    in
    if activities != null && hosts != { } then
      { error = "readData: pass either `hosts` or `activities`, not both"; }
    else if parsed ? error then
      parsed
    else
      {
        inherit system host;
        activities = enabled;
        rows = map (r: removeAttrs r [ "row" ]) parsed.rows;
        packages = map (r: {
          inherit (r)
            name
            version
            binaries
            activity
            ;
        }) selected;
        names = map (r: r.name) selected;
      };
in
{
  inherit readDataResult parseRows;

  # reprobuild.lib.readData { path, system, host, hosts ? {}, activities ? null }
  #
  # `path`: the data file. `system`: a target system (`x86_64-linux`, …,
  # `aarch64-windows`). `host`: the host name the guards' `host` is. The
  # enabled activities are `default` plus either `hosts.${host}` (the
  # profile's `hosts:` map) or `activities` (e.g. a `readIntent` result's
  # `evaluation.activities`). Returns `{ packages, names, rows, activities,
  # system, host }`: `packages` are the selected rows' `{ name, version,
  # binaries, activity }`, one per package, sorted by name; `rows` every
  # validated row. Throws with the planner's diagnostic for a file the
  # planner refuses, and for every file with `[[resource]]` rows.
  readData =
    args:
    let
      r = readDataResult args;
    in
    if r ? error then throw "reprobuild.lib.readData: ${r.error}" else r;
}
