## `repro home compare` -- the equivalence report between two host-facts
## documents (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
## §Measuring equivalence, §The report; user guide
## `docs/user-guide/host-facts.md`).
##
## Inputs: one host-facts document per side (`side = "nix"`, produced by
## `reprobuild.lib.homeManagerFacts`; `side = "reprobuild"`, produced by
## `repro home facts`) for the same host and target system, and optionally
## an allowlist of known differences.
##
## Per category (packages, files, environment, services) every entry is
## classified by its logical id:
##
## * `same` -- on both sides, every compared field equal;
## * `only-in-nix` / `only-in-reprobuild` -- on one side only;
## * `different` -- on both sides, at least one compared field differs (the
##   fields are named, with both values);
## * `unmapped` -- an entry its producer could not give a logical id (a Nix
##   package no contribution catalog claims, a Homebrew token resource). It
##   is listed, never compared, and never fails the comparison on its own:
##   a missing contribution is catalog work, not a configuration difference.
##
## Compared fields are every field of an entry except the informational
## ones (`HostFactsInformationalFields`: `id`, `origin`, `version`).
##
## The allowlist (TOML, `[[allow]]` rows) names known differences. Each row
## MUST carry a non-empty `reason` -- a row without one is a silent pass and
## is refused -- and may narrow itself by `status`, `id` (one id, or a
## prefix ending in `*`) and `hosts`. A row
## that applies to the compared host but matches no difference is STALE and
## fails the comparison: the difference it excused is gone, and a row left
## behind would silently excuse the next difference of that shape
## (Core-Invariants.md §Unrecognised Input Is Rejected, Not Skipped).
##
## Exit status (`compareExitCode`): 0 -- no difference outside the
## allowlist and no stale row; 1 -- a difference not allowlisted, or a stale
## row; 2 -- the inputs cannot be compared (unreadable or malformed facts,
## two documents of the same side, different hosts or systems, an invalid
## allowlist).

import std/[algorithm, json, sets, strutils, tables]

import toml_serialization
import toml_serialization/types as toml_types

import repro_home_apply/host_facts
import repro_profile/concerns

const
  AllowStatuses* = ["only-in-nix", "only-in-reprobuild", "different"]
    ## The statuses an allowlist row may name. `same` needs no excuse and
    ## `unmapped` never fails, so a row naming either could never be needed.
  AllowKeys = ["category", "status", "id", "hosts", "reason", "milestone"]

type
  ECompareInput* = object of CatchableError
    ## The inputs cannot be compared (exit 2).

  FieldDifference* = object
    field*: string
    nix*, reprobuild*: JsonNode     ## nil when the field is absent

  EntryResult* = object
    id*: string
    status*: string                 ## same | only-in-nix | only-in-reprobuild
                                    ## | different
    nix*, reprobuild*: JsonNode     ## the entries (nil on the absent side)
    fields*: seq[FieldDifference]   ## for `different`
    allowedBy*: int                 ## index into `CompareReport.allow`, -1

  CategoryResult* = object
    category*: string
    owner*: string                  ## GM7: which side applies the category
                                    ## on the host -- `reprobuild`, `nix`,
                                    ## or `split (...)` for packages -- when
                                    ## the Reprobuild document says its host
                                    ## declares `applies:`; "" otherwise
    entries*: seq[EntryResult]      ## sorted by id
    unmapped*: seq[JsonNode]        ## both sides' unmapped entries, each
                                    ## with a `side` field added

  AllowEntry* = object
    index*: int                     ## 1-based row number
    category*, status*, id*: string
    hosts*: seq[string]
    reason*, milestone*: string
    matched*: int

  CompareReport* = object
    host*, system*: string
    nixSource*, reprobuildSource*: string
    categories*: seq[CategoryResult]
    uncategorized*: seq[JsonNode]
    allow*: seq[AllowEntry]         ## every row of the allowlist
    failing*: int                   ## differences no row allows
    stale*: seq[int]                ## indexes into `allow`

proc fail(msg: string) {.noreturn.} =
  raise newException(ECompareInput, msg)

# ---------------------------------------------------------------------------
# Facts documents
# ---------------------------------------------------------------------------

proc requireString(node: JsonNode; key, where: string): string =
  if node.kind != JObject or not node.hasKey(key) or
      node[key].kind != JString or node[key].getStr.len == 0:
    fail(where & ": `" & key & "` must be a non-empty string")
  node[key].getStr

proc validateFacts*(doc: JsonNode; source: string) =
  ## Refuse a document that is not a host-facts document this `repro`
  ## reads. Unknown categories and malformed entries are refused, not
  ## skipped: a category the comparison ignored would be a silent pass.
  if doc.kind != JObject:
    fail(source & ": not a JSON object")
  if doc.getOrDefault("format") != %HostFactsFormat:
    fail(source & ": not a `" & HostFactsFormat & "` document")
  if doc.getOrDefault("schemaVersion") != %HostFactsSchemaVersion:
    fail(source & ": host-facts schemaVersion " &
      $doc.getOrDefault("schemaVersion") & " is not " &
      $HostFactsSchemaVersion & ", the version this repro compares")
  let side = requireString(doc, "side", source)
  if side notin ["nix", "reprobuild"]:
    fail(source & ": `side` must be \"nix\" or \"reprobuild\", not \"" &
      side & "\"")
  discard requireString(doc, "host", source)
  discard requireString(doc, "system", source)
  let cats = doc.getOrDefault("categories")
  if cats.isNil or cats.kind != JObject:
    fail(source & ": `categories` must be an object")
  for key, _ in cats:
    if key notin HostFactsCategories:
      fail(source & ": unknown category `" & key & "` (known: " &
        HostFactsCategories.join(", ") & ")")
  for c in HostFactsCategories:
    if not cats.hasKey(c) or cats[c].kind != JArray:
      fail(source & ": category `" & c & "` must be an array")
    var seen = initHashSet[string]()
    for e in cats[c]:
      let id = requireString(e, "id", source & " " & c & " entry")
      if id in seen:
        fail(source & ": two `" & c & "` entries with id `" & id & "`")
      seen.incl id
  # GM7: the informational `concerns` field (Reprobuild side). Optional; when
  # present it must be well formed, since the report reads ownership from it.
  let concernsNode = doc.getOrDefault("concerns")
  if not concernsNode.isNil:
    if concernsNode.kind != JObject or
        concernsNode.getOrDefault("declared").isNil or
        concernsNode["declared"].kind != JBool or
        concernsNode.getOrDefault("applied").isNil or
        concernsNode["applied"].kind != JArray:
      fail(source & ": `concerns` must be an object with a boolean " &
        "`declared` and an `applied` array")
    var names: seq[string]
    for n in concernsNode["applied"]:
      if n.kind != JString:
        fail(source & ": `concerns.applied` must hold concern names")
      names.add n.getStr
    let problem = concernListProblem(names)
    if problem.len > 0:
      fail(source & ": `concerns.applied`: " & problem)
  for listKey in ["unmapped", "uncategorized"]:
    let list = doc.getOrDefault(listKey)
    if list.isNil or list.kind != JArray:
      fail(source & ": `" & listKey & "` must be an array")
    for e in list:
      discard requireString(e, "id", source & " " & listKey & " entry")
      discard requireString(e, "reason", source & " " & listKey & " entry")

# ---------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------

proc tomlString(v: TomlValueRef; where, key: string): string =
  if v.kind != TomlKind.String:
    fail(where & ": `" & key & "` must be a string")
  v.stringVal

proc parseAllowlist*(content, source: string): seq[AllowEntry] =
  ## Parse and validate an allowlist. Every row needs a `category` and a
  ## non-empty `reason`; unknown keys, unknown categories and statuses, and
  ## an empty `hosts` list are refused.
  var root: TomlValueRef
  try:
    root = Toml.decode(content, TomlValueRef)
  except TomlError as e:
    fail(source & ": not valid TOML: " & e.msg)
  except CatchableError as e:
    fail(source & ": not valid TOML: " & e.msg)
  if root.isNil or root.kind notin {TomlKind.Table, TomlKind.InlineTable}:
    fail(source & ": not a TOML table")
  for key, value in root.tableVal[].pairs:
    if key != "allow":
      fail(source & ": unknown top-level key `" & key &
        "` (an allowlist holds `[[allow]]` rows only)")
    var rows: seq[TomlTableRef]
    case value.kind
    of TomlKind.Tables: rows = value.tablesVal
    of TomlKind.Array:
      for item in value.arrayVal:
        if item.kind notin {TomlKind.Table, TomlKind.InlineTable}:
          fail(source & ": `allow` must be an array of tables")
        rows.add item.tableVal
    else:
      fail(source & ": `allow` must be an array of tables (`[[allow]]`)")
    for i, row in rows:
      let where = source & " [[allow]] row " & $(i + 1)
      var e = AllowEntry(index: i + 1)
      for k, v in row[].pairs:
        if k notin AllowKeys:
          fail(where & ": unknown key `" & k & "` (known: " &
            AllowKeys.join(", ") & ")")
        case k
        of "category": e.category = tomlString(v, where, k)
        of "status": e.status = tomlString(v, where, k)
        of "id": e.id = tomlString(v, where, k)
        of "reason": e.reason = tomlString(v, where, k)
        of "milestone": e.milestone = tomlString(v, where, k)
        of "hosts":
          if v.kind != TomlKind.Array:
            fail(where & ": `hosts` must be an array of strings")
          for h in v.arrayVal:
            e.hosts.add tomlString(h, where, "hosts")
          if e.hosts.len == 0:
            fail(where & ": `hosts` is empty; omit it to apply to every host")
        else: discard
      if e.category.len == 0:
        fail(where & ": `category` is required (one of " &
          HostFactsCategories.join(", ") & ")")
      if e.category notin HostFactsCategories:
        fail(where & ": unknown category `" & e.category & "` (known: " &
          HostFactsCategories.join(", ") & ")")
      if e.id == "*":
        fail(where & ": `id = \"*\"` matches every entry; omit `id` to " &
          "say so")
      if e.status.len > 0 and e.status notin AllowStatuses:
        fail(where & ": status `" & e.status & "` cannot be allowlisted " &
          "(allowed: " & AllowStatuses.join(", ") & "; `same` needs no " &
          "excuse and `unmapped` never fails)")
      if e.reason.strip().len == 0:
        fail(where & ": `reason` is required and must not be empty -- an " &
          "allowlist entry without a reason is a silent pass")
      result.add e

proc appliesTo(e: AllowEntry; host: string): bool =
  e.hosts.len == 0 or host in e.hosts

proc idMatches(pattern, id: string): bool =
  ## An allowlist `id`: empty matches every id, one ending in `*` every id
  ## with that prefix, anything else exactly itself.
  if pattern.len == 0: true
  elif pattern.endsWith("*"): id.startsWith(pattern[0 ..< pattern.len - 1])
  else: pattern == id

proc matches(e: AllowEntry; category: string; r: EntryResult): bool =
  e.category == category and (e.status.len == 0 or e.status == r.status) and
    idMatches(e.id, r.id)

# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

proc fieldDifferences(nixE, reproE: JsonNode): seq[FieldDifference] =
  var keys: seq[string]
  for k, _ in nixE:
    if k notin keys: keys.add k
  for k, _ in reproE:
    if k notin keys: keys.add k
  keys.sort()
  for k in keys:
    if k in HostFactsInformationalFields:
      continue
    let a = nixE.getOrDefault(k)
    let b = reproE.getOrDefault(k)
    if a != b:
      result.add FieldDifference(field: k, nix: a, reprobuild: b)

proc indexById(list: JsonNode): OrderedTable[string, JsonNode] =
  for e in list:
    result[e["id"].getStr] = e

proc categoryOwner(reproDoc: JsonNode; category: string): string =
  ## Which side applies `category` on the host, from the Reprobuild
  ## document's `concerns` (Gradual-Nix-To-Reprobuild-Migration.md
  ## §Concern-scoped apply, "Host facts and the report"); "" when its host
  ## declares nothing (Reprobuild applies everything there, as before).
  let node = reproDoc.getOrDefault("concerns")
  if node.isNil or not node["declared"].getBool:
    return ""
  var names: seq[string]
  for n in node["applied"]:
    names.add n.getStr
  let applied = toConcernSet(names)
  proc side(c: HomeConcern): string =
    if c in applied: "reprobuild" else: "nix"
  case category
  of "packages":
    let a = side(hcApplications)
    let p = side(hcPackages)
    if a == p: a
    else: "split (applications: " & a & ", packages: " & p & ")"
  of "files": side(hcFiles)
  of "environment": side(hcEnvironment)
  of "services": side(hcServices)
  else: ""

proc compareFacts*(a, b: JsonNode; sourceA, sourceB: string;
                   allow: seq[AllowEntry] = @[]): CompareReport =
  ## Compare two validated-or-not facts documents (validated here). The
  ## order of `a` and `b` does not matter; their `side` fields decide which
  ## is which.
  validateFacts(a, sourceA)
  validateFacts(b, sourceB)
  if a["side"] == b["side"]:
    fail("both documents are `" & a["side"].getStr & "` facts (" & sourceA &
      ", " & sourceB & "); compare one `nix` and one `reprobuild` document")
  let (nixDoc, reproDoc, nixSrc, reproSrc) =
    if a["side"].getStr == "nix": (a, b, sourceA, sourceB)
    else: (b, a, sourceB, sourceA)
  if nixDoc["host"] != reproDoc["host"]:
    fail("the documents describe different hosts (nix: " &
      nixDoc["host"].getStr & ", reprobuild: " & reproDoc["host"].getStr & ")")
  if nixDoc["system"] != reproDoc["system"]:
    fail("the documents describe different systems (nix: " &
      nixDoc["system"].getStr & ", reprobuild: " &
      reproDoc["system"].getStr & ")")
  result.host = nixDoc["host"].getStr
  result.system = nixDoc["system"].getStr
  result.nixSource = nixSrc
  result.reprobuildSource = reproSrc
  result.allow = allow

  for c in HostFactsCategories:
    var cat = CategoryResult(category: c, owner: categoryOwner(reproDoc, c))
    let nixIdx = indexById(nixDoc["categories"][c])
    let reproIdx = indexById(reproDoc["categories"][c])
    var ids: seq[string]
    for id in nixIdx.keys: ids.add id
    for id in reproIdx.keys:
      if id notin nixIdx: ids.add id
    ids.sort()
    for id in ids:
      var r = EntryResult(id: id, allowedBy: -1,
        nix: nixIdx.getOrDefault(id), reprobuild: reproIdx.getOrDefault(id))
      if r.nix.isNil:
        r.status = "only-in-reprobuild"
      elif r.reprobuild.isNil:
        r.status = "only-in-nix"
      else:
        r.fields = fieldDifferences(r.nix, r.reprobuild)
        r.status = if r.fields.len == 0: "same" else: "different"
      if r.status != "same":
        for i in 0 ..< result.allow.len:
          if result.allow[i].appliesTo(result.host) and
              result.allow[i].matches(c, r):
            inc result.allow[i].matched
            if r.allowedBy < 0:
              r.allowedBy = i
        if r.allowedBy < 0:
          inc result.failing
      cat.entries.add r
    for (doc, side) in [(nixDoc, "nix"), (reproDoc, "reprobuild")]:
      for u in doc["unmapped"]:
        if u.getOrDefault("category") == %c:
          var copy = u.copy()
          copy["side"] = %side
          cat.unmapped.add copy
    result.categories.add cat
  for (doc, side) in [(nixDoc, "nix"), (reproDoc, "reprobuild")]:
    for u in doc["unmapped"]:
      let cat = u.getOrDefault("category")
      if cat.isNil or cat.kind != JString or cat.getStr notin HostFactsCategories:
        var copy = u.copy()
        copy["side"] = %side
        result.uncategorized.add copy
    for u in doc["uncategorized"]:
      var copy = u.copy()
      copy["side"] = %side
      result.uncategorized.add copy
  for i, e in result.allow:
    if e.appliesTo(result.host) and e.matched == 0:
      result.stale.add i

proc compareExitCode*(r: CompareReport): int =
  if r.failing > 0 or r.stale.len > 0: 1 else: 0

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc shortJson(n: JsonNode): string =
  if n.isNil: "(absent)" else: $n

proc describe(e: AllowEntry): string =
  result = "allow row " & $e.index & " (" & e.category
  if e.status.len > 0: result.add " " & e.status
  if e.id.len > 0: result.add " id=" & e.id
  if e.hosts.len > 0: result.add " hosts=" & e.hosts.join(",")
  result.add ")"

proc renderCompareText*(r: CompareReport; showSame = false): string =
  result = "repro home compare: host " & r.host & ", system " & r.system &
    " (nix: " & r.nixSource & "; reprobuild: " & r.reprobuildSource & ")\n"
  for cat in r.categories:
    var counts = initCountTable[string]()
    for e in cat.entries: counts.inc e.status
    result.add "[" & cat.category & "] " & $counts["same"] & " same, " &
      $counts["only-in-nix"] & " only in Nix, " &
      $counts["only-in-reprobuild"] & " only in Reprobuild, " &
      $counts["different"] & " different, " & $cat.unmapped.len &
      " unmapped" &
      (if cat.owner.len > 0: " -- applied by " & cat.owner & " on " & r.host
       else: "") & "\n"
    for e in cat.entries:
      if e.status == "same" and not showSame:
        continue
      var line = "  " & alignLeft(e.status, 19) & " " & e.id
      if e.status == "different":
        var parts: seq[string]
        for f in e.fields:
          parts.add f.field & ": nix=" & shortJson(f.nix) & " reprobuild=" &
            shortJson(f.reprobuild)
        line.add "  {" & parts.join("; ") & "}"
      if e.allowedBy >= 0:
        let a = r.allow[e.allowedBy]
        line.add "  [allowed: " & a.reason &
          (if a.milestone.len > 0: " -- " & a.milestone else: "") & "]"
      elif e.status != "same":
        line.add "  [NOT ALLOWED]"
      result.add line & "\n"
    for u in cat.unmapped:
      result.add "  unmapped (" & u["side"].getStr & ") " & u["id"].getStr &
        ": " & u["reason"].getStr & "\n"
  if r.uncategorized.len > 0:
    result.add "[uncategorized] " & $r.uncategorized.len &
      " entr" & (if r.uncategorized.len == 1: "y" else: "ies") &
      " no category covers (listed, not compared)\n"
    for u in r.uncategorized:
      result.add "  (" & u["side"].getStr & ") " & u["id"].getStr & ": " &
        u["reason"].getStr & "\n"
  for i in r.stale:
    result.add "stale: " & describe(r.allow[i]) &
      " matches no difference on host " & r.host & " -- remove it (reason: " &
      r.allow[i].reason & ")\n"
  result.add "result: " & $r.failing & " difference(s) not allowlisted, " &
    $r.stale.len & " stale allowlist row(s); exit " & $compareExitCode(r) &
    "\n"

proc renderCompareJson*(r: CompareReport): JsonNode =
  result = %*{"host": r.host, "system": r.system,
    "nixSource": r.nixSource, "reprobuildSource": r.reprobuildSource,
    "failing": r.failing, "exitCode": compareExitCode(r)}
  var cats = newJObject()
  for cat in r.categories:
    var c = newJObject()
    for status in ["same", "only-in-nix", "only-in-reprobuild", "different"]:
      c[status] = newJArray()
    for e in cat.entries:
      var item = %*{"id": e.id}
      if e.status == "different":
        var fields = newJArray()
        for f in e.fields:
          fields.add %*{"field": f.field,
            "nix": (if f.nix.isNil: newJNull() else: f.nix),
            "reprobuild": (if f.reprobuild.isNil: newJNull() else: f.reprobuild)}
        item["fields"] = fields
      if e.allowedBy >= 0:
        item["allowedBy"] = %r.allow[e.allowedBy].index
      c[e.status].add item
    c["unmapped"] = %cat.unmapped
    if cat.owner.len > 0:
      c["owner"] = %cat.owner
    cats[cat.category] = c
  result["categories"] = cats
  result["uncategorized"] = %r.uncategorized
  var stale = newJArray()
  for i in r.stale:
    stale.add %*{"row": r.allow[i].index, "category": r.allow[i].category,
      "status": r.allow[i].status, "id": r.allow[i].id,
      "reason": r.allow[i].reason}
  result["staleAllowRows"] = stale
