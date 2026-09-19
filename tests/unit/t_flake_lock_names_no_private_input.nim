## A lock file is a publication. Nothing in it may name a repository the
## public cannot see.
##
## What this is about, stated plainly because the cost is easy to
## under-read. A `flake.lock` node does not merely record that a dependency
## exists. It records the clone URL twice (`locked` and `original`), the
## branch, the exact commit, the repository's COMMIT COUNT, the hash of its
## tree and when it last moved. Against a repository only an employee can
## clone, that is its name, its release branch, roughly how big it is and
## how recently someone worked on it — published, in a repository anyone can
## read, in a file a machine rewrites.
##
## And it propagates. A `flake = false` source input declared HERE is copied
## verbatim into the lock of every flake that takes this one, and into the
## lock of every flake that takes those. One line in `flake.nix` put the
## same URL into seven public repositories. That is why the fix is a gate and
## not an edit: deleting a node by hand breaks the build, and the next
## `nix flake lock` anywhere in the chain writes it straight back.
##
## The invariant, and where it bites
## ---------------------------------
## Two different statements, asserted separately because only one of them is
## inside this repository's control:
##
##   * Nothing this flake DECLARES may be non-public. This is the durable
##     one. Every leak the workspace has had originated in a declared input.
##   * Nothing this flake INHERITS may be non-public either — but an
##     inherited node arrives through somebody else's flake, so the set of
##     them is pinned as an explicitly recorded, explicitly shrinking
##     residual rather than asserted empty. Adding one fails. Keeping a row
##     after the cascade has cleared it fails too.
##
## Visibility is read from the GitHub API, not guessed, and not taken from a
## list of known-bad names: a denylist passes on the day the SECOND private
## input appears, which is the whole failure this file exists to prevent.
## The API answer is cached in `scripts/flake-input-visibility.tsv` so the
## offline arm has something total to check against, and the cache is
## regenerated — never hand-edited — by running this gate with
## `REPRO_FLAKE_VISIBILITY_REFRESH=1`.
##
## The limit, stated rather than left to be discovered: offline, a row that
## LIES about a repository's visibility passes. That is what the API arm is
## for, and it is why the offline arm is fail-closed on an identity it has
## never seen — an unknown identity is a failure, not a pass, so a new input
## cannot arrive quietly even when nothing can reach the network.
##
## No mocks. The lock files are real, the scratch locks are real files on
## disk, and the visibility answers come from the real API.

import std/[algorithm, json, os, osproc, sequtils, sets, strutils, tables,
            tempfiles, unittest]

const
  VisibilityFile = "scripts/flake-input-visibility.tsv"
  RefreshEnvVar = "REPRO_FLAKE_VISIBILITY_REFRESH"
  PublicMark = "public"
  NonVcsMark = "non-vcs"
    ## Tarball and file inputs name a URL, not a repository. They are
    ## recorded so that coverage is TOTAL — an identity with no row is a
    ## failure, so every shape the lock can hold needs a shape of row.
  UnverifiedMark = "unverified-host"
    ## A REPOSITORY whose visibility this gate has no client to ask about:
    ## a `gitlab` or `sourcehut` node, or a `git` node on a host that is
    ## not GitHub. This is a separate word from `non-vcs` on purpose, and
    ## the separation is a fix rather than a refinement. Recording such an
    ## identity as "not a repository" made every assertion below skip it,
    ## so a PRIVATE GitLab input would have passed in silence — and this
    ## repository's own lock already carries three identities of that
    ## shape (`rycee/nmt`, `~rycee/nmd`, `spectrum-os.org/git/spectrum`).
    ## They are now pinned as an explicit, set-equal list of things this
    ## gate does NOT establish, so a fourth one fails instead of joining
    ## them quietly, and a DECLARED input may not be one at all.
  SeededIdentity = "example-invalid/a-repository-this-gate-invented"
    ## The identity both fixture cases seed. It is deliberately NOT a real
    ## repository, and that is a correction: an earlier version of this
    ## file hard-coded a genuinely private repository on the theory that
    ## the negative case needed one, which named a private repository in a
    ## public file for nothing. The case never asks the API — it hands
    ## `offendersIn` a visibility table — so the answer is INJECTED below
    ## and the name only has to be one no real lock can collide with.
    ##
    ## Injecting it is also what makes the case a check. Read against the
    ## recorded cache, "a private repository is rejected" was satisfied by
    ## the UNKNOWN verdict as readily as by the NON-PUBLIC one: seeding an
    ## identity with no row at all was GREEN, so the branch that compares
    ## a recorded answer to `public` had no case, and the day the cache
    ## stopped carrying a non-public row it would have had none silently.
    ## The two refusals are now asserted apart, each on its own verdict.
  SeededPublicIdentity = "nixos/nixpkgs"
    ## The polarity control. Without it, an implementation that rejects
    ## every lock it is handed passes the negative case forever. This one
    ## IS a real identity, and deliberately: its row comes from the cache
    ## rather than from the test, so the `.git`-suffix and `?ref=` strips
    ## have to resolve it to the same key the API answered about.

const VcsOtherKind = "git-other"
  ## A `git` node whose URL is not on github.com. It names a repository;
  ## this gate simply has no client that can ask that host about it.

type
  Identity = object
    key: string       ## `owner/repo`, lowercased, or the URL for non-VCS
    kind: string      ## github | gitlab | sourcehut | git-other | non-vcs
  LockVerdict = enum
    lvCovered          ## a lock was found and read
    lvNotCovered       ## no lock file here -- NOT the same as passing

proc reproRoot(): string =
  var dir = parentDir(currentSourcePath())
  while dir.len > 0 and dir != parentDir(dir):
    if fileExists(dir / "flake.nix") and fileExists(dir / "flake.lock") and
       fileExists(dir / "config.nims"):
      return dir
    dir = parentDir(dir)
  raise newException(IOError,
    "could not locate the repository root from " & currentSourcePath())

proc githubIdentityFromUrl(url: string): string =
  ## Pull `owner/repo` out of a bare clone URL.
  ##
  ## This is not incidental tidying. The same private repository appears in
  ## these locks in BOTH shapes — as a `type: "github"` node with `owner`
  ## and `repo` fields, and as a `type: "git"` node whose URL is a plain
  ## `https://github.com/...` string, sometimes with a `.git` suffix and
  ## sometimes with a `?ref=` query. A scan that reads only the structured
  ## fields sees one of them and misses the other, and the one it misses is
  ## the shape the leak actually had.
  var rest = url
  for prefix in ["git+https://github.com/", "git+http://github.com/",
                 "https://github.com/", "http://github.com/",
                 "ssh://git@github.com/", "git@github.com:"]:
    if rest.startsWith(prefix):
      rest = rest[prefix.len .. ^1]
      break
  if rest == url:
    return ""
  for cut in ['?', '#']:
    let at = rest.find(cut)
    if at >= 0:
      rest = rest[0 ..< at]
  rest.removeSuffix("/")
  rest.removeSuffix(".git")
  let parts = rest.split('/')
  if parts.len < 2 or parts[0].len == 0 or parts[1].len == 0:
    return ""
  (parts[0] & "/" & parts[1]).toLowerAscii()

proc identityOf(node: JsonNode): seq[Identity] =
  ## Every repository identity one `locked` / `original` object names.
  if node == nil or node.kind != JObject:
    return
  let kind = if node.hasKey("type"): node["type"].getStr() else: ""
  case kind
  of "github", "gitlab", "sourcehut":
    let owner = node{"owner"}.getStr()
    let repo = node{"repo"}.getStr()
    if owner.len > 0 and repo.len > 0:
      result.add Identity(key: (owner & "/" & repo).toLowerAscii(), kind: kind)
  of "git":
    let url = node{"url"}.getStr()
    let gh = githubIdentityFromUrl(url)
    if gh.len > 0:
      result.add Identity(key: gh, kind: "github")
    elif url.len > 0:
      # A `git` node is a REPOSITORY whatever host it names. Calling a
      # non-GitHub one "not a repository" is what let the assertions below
      # skip it, which is a fail-open and not a simplification.
      result.add Identity(key: url.split('?')[0], kind: VcsOtherKind)
  of "tarball", "file":
    let url = node{"url"}.getStr()
    let gh = githubIdentityFromUrl(url)
    if gh.len > 0:
      result.add Identity(key: gh, kind: "github")
    elif url.len > 0:
      result.add Identity(key: url.split('?')[0], kind: NonVcsMark)
  of "path", "indirect":
    discard
  else:
    if node.hasKey("url"):
      result.add Identity(key: node["url"].getStr().split('?')[0],
                          kind: NonVcsMark)

proc readLock(path: string): (LockVerdict, JsonNode) =
  ## A missing lock is NOT a pass. It is an absence of evidence, and this
  ## gate reports it as one: the two repositories in this workspace that
  ## carry no lock at all are clean by accident, and a green tick against
  ## them is exactly the false green that lets the node back in the moment
  ## either of them gains one.
  if not fileExists(path):
    return (lvNotCovered, nil)
  (lvCovered, parseFile(path))

proc identitiesInLock(lock: JsonNode): OrderedTable[string, Identity] =
  result = initOrderedTable[string, Identity]()
  if lock == nil or not lock.hasKey("nodes"):
    return
  for _, node in lock["nodes"].pairs:
    for field in ["locked", "original"]:
      if node.hasKey(field):
        for ident in identityOf(node[field]):
          if not result.hasKey(ident.key):
            result[ident.key] = ident

proc declaredInputNames(flakeNix: string): HashSet[string] =
  ## The names inside the top-level `inputs = { ... }` block. Read from the
  ## file rather than from the lock, because the lock cannot distinguish an
  ## input this repository chose from one it merely inherited, and the
  ## difference is the whole point of the two separate assertions below.
  result = initHashSet[string]()
  let at = flakeNix.find("\n  inputs = {")
  if at < 0:
    return
  var depth = 0
  var i = flakeNix.find('{', at)
  let start = i
  while i < flakeNix.len:
    if flakeNix[i] == '{': inc depth
    elif flakeNix[i] == '}':
      dec depth
      if depth == 0: break
    inc i
  let body = flakeNix[start + 1 ..< i]
  var lineDepth = 0
  for raw in body.splitLines():
    let line = raw.strip()
    let openers = raw.count('{')
    let closers = raw.count('}')
    if lineDepth == 0 and not line.startsWith("#") and line.contains("="):
      # Both spellings are a declaration: `name = { ... };` and the dotted
      # `name.url = "...";` / `name.follows = "...";`. Reading only the
      # brace form drops four inputs here, including the one every other
      # input follows -- so the stem before the first `.` is the name.
      var name = line.split('=')[0].strip()
      let dot = name.find('.')
      if dot > 0:
        name = name[0 ..< dot]
      if name.len > 0 and not name.contains(' '):
        result.incl name
    lineDepth += openers - closers

proc identitiesOfDeclaredInputs(lock: JsonNode;
                                declared: HashSet[string]): OrderedTable[string, Identity] =
  ## Map each DECLARED input name onto the identity its root node resolves
  ## to. The root node's `inputs` table is the authority on which lock node
  ## a declared name reaches.
  result = initOrderedTable[string, Identity]()
  if lock == nil or not lock.hasKey("nodes"):
    return
  let rootName = lock{"root"}.getStr("root")
  if not lock["nodes"].hasKey(rootName):
    return
  let rootInputs = lock["nodes"][rootName]{"inputs"}
  if rootInputs == nil:
    return
  for name, target in rootInputs.pairs:
    if name notin declared:
      continue
    if target.kind != JString:
      continue
    let nodeName = target.getStr()
    if not lock["nodes"].hasKey(nodeName):
      continue
    let node = lock["nodes"][nodeName]
    for field in ["locked", "original"]:
      if node.hasKey(field):
        for ident in identityOf(node[field]):
          if not result.hasKey(ident.key):
            result[ident.key] = ident

proc readVisibility(path: string): OrderedTable[string, string] =
  result = initOrderedTable[string, string]()
  if not fileExists(path):
    return
  for raw in readFile(path).splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let parts = line.split('\t')
    if parts.len >= 2:
      result[parts[0].strip().toLowerAscii()] = parts[1].strip()

proc ghVisibility(identity: string): string =
  ## Ask the GitHub API. Returns the raw answer (`PUBLIC` / `PRIVATE` /
  ## `INTERNAL`) or the empty string when the question could not be put.
  ##
  ## `INTERNAL` is a real third answer in this workspace and it is why the
  ## comparison below is `== public` and not `!= private`: those two
  ## spellings of "the check" disagree about an internal repository, and
  ## only one of them is safe.
  let gh = findExe("gh")
  if gh.len == 0:
    return ""
  let (output, code) = execCmdEx(gh & " repo view " & quoteShell(identity) &
    " --json visibility -q .visibility 2>/dev/null")
  if code != 0:
    return ""
  output.strip()

proc apiIsReachable(): bool =
  let gh = findExe("gh")
  if gh.len == 0:
    return false
  let (_, code) = execCmdEx(gh & " auth status >/dev/null 2>&1")
  code == 0

type NodeShape = enum
  nsGithubTyped      ## `"type": "github"` with `owner` / `repo` fields
  nsPlainGitUrl      ## `"type": "git"`, `https://github.com/o/r`
  nsGitPlusRefUrl    ## `"type": "git"`, `git+https://github.com/o/r?ref=b`
  nsDotGitSuffixUrl  ## `"type": "git"`, `https://github.com/o/r.git`
  nsGitlabTyped      ## `"type": "gitlab"` with `owner` / `repo` fields
  nsForeignGitUrl    ## `"type": "git"` on a host that is not github.com

proc scratchIdentityKey(identity: string; shape: NodeShape): string =
  ## The key `identityOf` will produce for this fixture. Returning it from
  ## the fixture rather than assuming it is what keeps the fixture set
  ## honest: a shape whose key the test cannot state is a shape the test
  ## cannot assert on, and both cases below seed their visibility answer
  ## under exactly this key.
  case shape
  of nsForeignGitUrl: "https://git.invalid.example/" & identity
  else: identity.toLowerAscii()

proc writeScratchLock(dir, identity: string; shape: NodeShape): string =
  ## Build a minimal but STRUCTURALLY REAL lock: a root node with one
  ## input, and that input's node carrying the identity in one of the
  ## shapes a `flake.lock` can hold. Every case below iterates the whole
  ## `NodeShape` enum, so adding a shape here extends the fixture set
  ## rather than leaving it behind.
  ##
  ## More than two, and that is a correction rather than thoroughness for
  ## its own sake. The private input was spelled `git+https://...?ref=` in
  ## `flake.nix` and recorded as a plain `https://...` in the lock, so a
  ## scan can be blind to one spelling of the very same repository while
  ## matching the other, and a negative case that seeds only the spelling
  ## the scan happens to handle reports a coverage it does not have. A
  ## mutation that removed the `git+https://` prefix from the matcher was
  ## GREEN against the earlier two-shape version of this case.
  ##
  ## The last two shapes were added by review, after measuring what the
  ## locks in this workspace actually contain: `gitlab` and `sourcehut`
  ## nodes carry the same `owner` / `repo` pair as `github` ones, and a
  ## `git` node can name a host that is not GitHub at all. Both occur in
  ## this repository's own lock, and both used to be recorded as though
  ## they were not repositories.
  let parts = identity.split('/')
  let url =
    case shape
    of nsPlainGitUrl: "https://github.com/" & identity
    of nsGitPlusRefUrl: "git+https://github.com/" & identity & "?ref=stable"
    of nsDotGitSuffixUrl: "https://github.com/" & identity & ".git"
    of nsForeignGitUrl: "https://git.invalid.example/" & identity
    of nsGithubTyped, nsGitlabTyped: ""
  let typedHost = if shape == nsGitlabTyped: "gitlab" else: "github"
  let node =
    if shape in {nsGithubTyped, nsGitlabTyped}:
      """{ "locked": { "type": """" & typedHost & """", "owner": """" &
        parts[0] & """", "repo": """" & parts[1] &
        """", "rev": "0123456789abcdef0123456789abcdef01234567" },
          "original": { "type": """" & typedHost & """", "owner": """" &
        parts[0] & """", "repo": """" & parts[1] & """" }, "flake": false }"""
    else:
      """{ "locked": { "type": "git", "url": """" & url &
        """", "rev": "0123456789abcdef0123456789abcdef01234567" },
          "original": { "type": "git", "url": """" & url &
        """" }, "flake": false }"""
  let text = """{ "nodes": { "root": { "inputs": { "seeded": "seeded" } },
    "seeded": """ & node & """ }, "root": "root", "version": 7 }"""
  let path = dir / "flake.lock"
  writeFile(path, text)
  path

proc offendersIn(lockPath: string;
                 visibility: OrderedTable[string, string]): seq[string] =
  ## The rejection message, built the way a reader needs it: the repository
  ## AND the file it was found in. A verdict that names neither is a verdict
  ## nobody can act on.
  let (verdict, lock) = readLock(lockPath)
  if verdict == lvNotCovered:
    return @["NOT COVERED: " & lockPath & " does not exist"]
  for key, ident in identitiesInLock(lock).pairs:
    if ident.kind == NonVcsMark:
      continue
    if not visibility.hasKey(key):
      # A DISTINCT verdict from the one below, and the distinction is the
      # point: "this repository is not public" and "nobody has ever
      # resolved this repository" are different findings, and a negative
      # case that accepts either as proof of the first has no case for it.
      result.add "UNKNOWN: " & key & " in " & lockPath &
        " has no recorded visibility"
    elif visibility[key] == UnverifiedMark:
      result.add "UNVERIFIED: " & key & " in " & lockPath &
        " is a repository this gate has no client to ask about"
    elif visibility[key] != PublicMark:
      result.add "NON-PUBLIC: " & key & " (" & visibility[key] & ") in " &
        lockPath

let root = reproRoot()
let visibilityPath = root / VisibilityFile

# ---------------------------------------------------------------------------
# Refresh mode. Running this gate with REPRO_FLAKE_VISIBILITY_REFRESH=1
# rewrites the recorded answers from the API. The cache is GENERATED, never
# hand-maintained, because a hand-maintained list of 70-odd repositories is
# a list that rots and then passes.
# ---------------------------------------------------------------------------
if getEnv(RefreshEnvVar) == "1":
  let (_, lock) = readLock(root / "flake.lock")
  let refreshDeclared = identitiesOfDeclaredInputs(lock,
    declaredInputNames(readFile(root / "flake.nix")))
  var rows: seq[string] = @[]
  var residual: seq[string] = @[]
  var unverifiable: seq[string] = @[]
  for key, ident in identitiesInLock(lock).pairs:
    if ident.kind == NonVcsMark:
      rows.add key & "\t" & NonVcsMark
      continue
    if ident.kind != "github":
      # A repository on a host with no client here. It used to be written
      # as `non-vcs`, which made every assertion skip it; it is now its
      # own word and its own asserted list.
      rows.add key & "\t" & UnverifiedMark
      unverifiable.add "# unverifiable: " & key &
        " -- a " & ident.kind & " repository; this gate has no client for " &
        "that host, so its visibility is NOT established here"
      continue
    let answer = ghVisibility(key)
    if answer.len == 0:
      quit("refresh: could not resolve the visibility of " & key &
        "; refusing to write a cache with a guess in it", 1)
    rows.add key & "\t" & answer.toLowerAscii()
    if answer.toLowerAscii() != PublicMark and not refreshDeclared.hasKey(key):
      residual.add "# residual: " & key &
        " -- inherited through an upstream flake's own pin; clears when that " &
        "pin moves past the commit that dropped the input"
  sort(rows)
  sort(residual)
  sort(unverifiable)
  writeFile(visibilityPath,
    "# GENERATED by tests/unit/t_flake_lock_names_no_private_input.nim.\n" &
    "# Regenerate with: " & RefreshEnvVar & "=1 <the compiled gate>\n" &
    "# Do NOT hand-edit: a hand-written row is a guess, and a guess that\n" &
    "# says `public` about a private repository is precisely the failure\n" &
    "# this file is here to make impossible.\n" &
    "#\n" &
    "# A `# residual:` line records an identity this repository does NOT\n" &
    "# declare and cannot make public from here. The gate asserts the set of\n" &
    "# them EXACTLY, so a new one fails and a stale one fails too.\n" &
    "#\n" &
    "# An `# unverifiable:` line records a REPOSITORY this gate cannot ask\n" &
    "# about, because it is not on GitHub and there is no client here for\n" &
    "# its host. That is NOT the same as `non-vcs`, which means the entry\n" &
    "# is an archive rather than a repository. The set of them is asserted\n" &
    "# exactly, so a new non-GitHub input fails rather than joining the\n" &
    "# list silently, and no DECLARED input is allowed to be one.\n" &
    "#\n" &
    "# A non-public row is expected to be TRANSIENT, and it does cost\n" &
    "# something while it is here: it puts the word next to a name this\n" &
    "# file would otherwise only be repeating from the lock beside it. That\n" &
    "# is the trade for a gate that fails when a second one appears, and it\n" &
    "# ends when the row does -- this file is regenerated from the lock, so\n" &
    "# an identity that leaves the lock leaves this file on the next\n" &
    "# refresh.\n" &
    (if residual.len == 0: "" else: residual.join("\n") & "\n") &
    (if unverifiable.len == 0: "" else: unverifiable.join("\n") & "\n") &
    "# identity\tvisibility\n" & rows.join("\n") & "\n")
  echo "wrote ", rows.len, " rows to ", visibilityPath
  quit(0)

suite "no flake.lock in this repository names a private repository":

  let visibility = readVisibility(visibilityPath)
  let (rootVerdict, rootLock) = readLock(root / "flake.lock")
  let flakeNix = readFile(root / "flake.nix")
  let declaredNames = declaredInputNames(flakeNix)
  let lockIdentities = identitiesInLock(rootLock)
  let declaredIdentities = identitiesOfDeclaredInputs(rootLock, declaredNames)

  test "this repository's lock is covered, and the scan found real inputs":
    # The floors. Every assertion below is over a set, and an empty set
    # satisfies all of them; these are what stop a scanner that resolves
    # nothing from reporting a clean tree forever.
    check rootVerdict == lvCovered
    # Vacuity floors, deliberately far below the real counts (22 / 78 / 19
    # at the time of writing). They are not the assertion -- they are what
    # stops a parser that silently matches nothing from satisfying every
    # set-based assertion below by handing each of them an empty set.
    check declaredNames.len >= 15
    check lockIdentities.len >= 50
    check declaredIdentities.len >= 12
    check visibility.len >= lockIdentities.len

  test "every identity in the lock has a recorded visibility":
    # FAIL-CLOSED ON UNKNOWN. A new input cannot arrive quietly, with or
    # without a network: an identity nobody has resolved is a failure.
    var unknown: seq[string] = @[]
    for key, ident in lockIdentities.pairs:
      if not visibility.hasKey(key):
        unknown.add key & " (" & ident.kind & ")"
    if unknown.len > 0:
      echo "identities with no recorded visibility: ", unknown.join(", ")
      echo "refresh with: ", RefreshEnvVar, "=1 <this binary>"
    check unknown.len == 0

  test "no input this flake DECLARES names a non-public repository":
    # THE durable invariant, and the one entirely inside this repository's
    # control. Every leak this workspace has had originated here.
    #
    # `UnverifiedMark` is a FAILURE here and not an exemption. What this
    # repository chooses to declare, it must be able to prove public; an
    # input on a host nothing here can ask about is a declaration whose
    # visibility nobody establishes, which is the same hole under a
    # politer name. The inherited half below tolerates them, because they
    # arrive through somebody else's flake, and pins them as a set.
    var offenders: seq[string] = @[]
    for key, ident in declaredIdentities.pairs:
      if ident.kind == NonVcsMark:
        continue
      let recorded = visibility.getOrDefault(key, "unrecorded")
      if recorded != PublicMark and recorded != NonVcsMark:
        offenders.add key & " -> " & recorded
    if offenders.len > 0:
      echo "declared inputs that are not public: ", offenders.join(", ")
    check offenders.len == 0

  test "the non-public identities inherited from upstream are exactly the recorded residual":
    # Inherited nodes arrive through somebody else's flake, so they cannot
    # be asserted away from here. They are pinned instead: a set equality,
    # so a NEW one fails, and so does a row left behind after the upstream
    # cascade has cleared it. The steady state of this set is empty.
    var inherited = initHashSet[string]()
    for key, ident in lockIdentities.pairs:
      if ident.kind == NonVcsMark:
        continue
      if declaredIdentities.hasKey(key):
        continue
      let recorded = visibility.getOrDefault(key, "unrecorded")
      if recorded == UnverifiedMark:
        # Answered by the case below, which pins the whole set of them.
        # Folding them in here would say "private" about repositories
        # nobody has asked about, which is a different claim.
        continue
      if recorded != PublicMark and recorded != NonVcsMark:
        inherited.incl key
    var recordedResidual = initHashSet[string]()
    for raw in readFile(visibilityPath).splitLines():
      if raw.startsWith("# residual:"):
        recordedResidual.incl raw.split(':', 1)[1].strip().split(' ')[0]
    if inherited != recordedResidual:
      echo "inherited non-public: ", toSeq(inherited).join(", ")
      echo "recorded residual:    ", toSeq(recordedResidual).join(", ")
    check inherited == recordedResidual

  test "the repository identities this gate cannot verify are exactly the recorded list":
    # THE COVERAGE ADMISSION, asserted rather than left implicit. A
    # `gitlab` / `sourcehut` node, or a `git` node on a host that is not
    # GitHub, names a repository this gate has no client to ask about.
    # Recording those as `non-vcs` — "not a repository" — made every
    # assertion above skip them, so a PRIVATE GitLab input would have
    # passed in silence. They are now their own word and their own set
    # equality: a fourth one fails, and a line left behind after an input
    # leaves fails too.
    # The set is computed from the identity's KIND, not from the recorded
    # word. Reading the cache for both sides would make this case agree
    # with a classifier that had stopped seeing these nodes as
    # repositories at all -- which is precisely the defect being fixed.
    # The cache is then required to AGREE with the classifier.
    var unverifiable = initHashSet[string]()
    for key, ident in lockIdentities.pairs:
      if ident.kind == "github" or ident.kind == NonVcsMark:
        continue
      unverifiable.incl key
      check visibility.getOrDefault(key, "unrecorded") == UnverifiedMark
    var recorded = initHashSet[string]()
    for raw in readFile(visibilityPath).splitLines():
      if raw.startsWith("# unverifiable:"):
        recorded.incl raw.split(':', 1)[1].strip().split(' ')[0]
    if unverifiable != recorded:
      echo "unverifiable in the lock: ", toSeq(unverifiable).join(", ")
      echo "recorded as unverifiable: ", toSeq(recorded).join(", ")
    check unverifiable == recorded

  test "a lock naming a private repository is rejected, naming repo and file":
    # NEGATIVE. Every node shape, because the leak had more than one and a
    # scan that reads only the structured fields passes the one it cannot
    # see. The visibility answer is INJECTED under the key the fixture
    # itself reports, which is what makes this a case about the
    # NON-PUBLIC branch rather than about whatever the cache happens to
    # hold: seeded against the recorded cache with an identity that had no
    # row, this case was GREEN on the UNKNOWN verdict instead, and the
    # branch it is named for had no case at all.
    for shape in NodeShape:
      let dir = createTempDir("repro-lock-gate-", "-private")
      try:
        let key = scratchIdentityKey(SeededIdentity, shape)
        var seeded = visibility
        seeded[key] = "private"
        let path = writeScratchLock(dir, SeededIdentity, shape)
        let offenders = offendersIn(path, seeded)
        check offenders.len == 1
        if offenders.len != 1:
          echo "shape ", shape, " produced ", offenders.len, " offender(s): ",
            offenders.join("; ")
        else:
          # The VERDICT, not merely a rejection. "UNKNOWN" and
          # "UNVERIFIED" also name the repository and the file.
          check offenders[0].startsWith("NON-PUBLIC:")
          check offenders[0].contains(key)
          check offenders[0].contains(path)
      finally:
        removeDir(dir)

  test "a lock naming a repository nobody has resolved is UNKNOWN, not private":
    # The other refusal, separated from the one above so neither can stand
    # in for the other. Fail-closed is still fail-closed — the identity is
    # rejected — but the verdict says which question went unanswered.
    for shape in NodeShape:
      let dir = createTempDir("repro-lock-gate-", "-unknown")
      try:
        let key = scratchIdentityKey(SeededIdentity, shape)
        let path = writeScratchLock(dir, SeededIdentity, shape)
        let offenders = offendersIn(path, visibility)
        check offenders.len == 1
        if offenders.len == 1:
          check offenders[0].startsWith("UNKNOWN:")
          check offenders[0].contains(key)
      finally:
        removeDir(dir)

  test "a lock naming only public repositories is accepted":
    # POLARITY CONTROL. A gate that refuses everything satisfies the cases
    # above and protects nothing. The injection is under the key the
    # fixture reports, so a matcher that resolves the URL to a DIFFERENT
    # key -- dropping the `.git` strip, or the `git+https://` prefix --
    # still fails here, which is the mutation this case was written for.
    for shape in NodeShape:
      let dir = createTempDir("repro-lock-gate-", "-public")
      try:
        let key = scratchIdentityKey(SeededPublicIdentity, shape)
        var seeded = visibility
        seeded[key] = PublicMark
        let path = writeScratchLock(dir, SeededPublicIdentity, shape)
        let offenders = offendersIn(path, seeded)
        if offenders.len != 0:
          echo "shape ", shape, " rejected a public lock: ",
            offenders.join("; ")
        check offenders.len == 0
      finally:
        removeDir(dir)

  test "a directory with no lock is NOT COVERED, not passing":
    let dir = createTempDir("repro-lock-gate-", "-absent")
    try:
      let (verdict, _) = readLock(dir / "flake.lock")
      check verdict == lvNotCovered
      let offenders = offendersIn(dir / "flake.lock", visibility)
      check offenders.len == 1
      check offenders[0].startsWith("NOT COVERED")
    finally:
      removeDir(dir)

  test "the recorded visibilities agree with the GitHub API":
    # The arm that makes the recorded answers answers rather than claims.
    # It needs an authenticated client: anonymous api.github.com returns
    # 403 from at least one host this suite runs on, and 403 is not an
    # answer about visibility.
    if not apiIsReachable():
      echo "NOT RUN: no authenticated `gh`; the recorded visibilities were ",
        "not re-checked against the API on this host. The fail-closed ",
        "coverage case above still holds."
      # Not a free pass. What the offline branch CAN still establish is that
      # the answers it is trusting were machine-written, so a row nobody
      # could have obtained from the API is refused here rather than
      # inherited as fact.
      check readFile(visibilityPath).startsWith("# GENERATED by")
    else:
      var contradictions: seq[string] = @[]
      var asked = 0
      for key, recorded in visibility.pairs:
        if recorded == NonVcsMark:
          continue
        let answer = ghVisibility(key).toLowerAscii()
        if answer.len == 0:
          continue
        inc asked
        if answer != recorded:
          contradictions.add key & ": recorded " & recorded & ", API says " &
            answer
      if contradictions.len > 0:
        echo "recorded visibility contradicted by the API: ",
          contradictions.join("; ")
      check asked > 0
      check contradictions.len == 0
