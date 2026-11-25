#!/usr/bin/env python3
"""Render generated regions in docs/users/content/ and repository-root llms*.txt.

Usage:
    python3 scripts/render_user_docs_generated.py          # rewrite generated regions and llms*.txt
    python3 scripts/render_user_docs_generated.py --check  # exit 1 if any file is stale

Sources of truth:
- libs/repro_cli_support/src/repro_cli_support/cli_description.nim (CLI commands, subcommands, flags)
- libs/repro_cli_support/src/repro_cli_support.nim (repro health check names)
- scripts/install/repro-install.sh and scripts/install/repro-install.ps1 (installer options)
- reprobuild.nimble (current release version)
- docs/users/content/**/*.md (front-matter titles, descriptions and routes)
"""

from __future__ import annotations

import pathlib
import re
import sys
from dataclasses import dataclass, field

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLI_DESC = ROOT / "libs/repro_cli_support/src/repro_cli_support/cli_description.nim"
CLI_SUPPORT = ROOT / "libs/repro_cli_support/src/repro_cli_support.nim"
INSTALL_SH = ROOT / "scripts/install/repro-install.sh"
INSTALL_PS1 = ROOT / "scripts/install/repro-install.ps1"
NIMBLE = ROOT / "reprobuild.nimble"
CONTENT_DIR = ROOT / "docs/users/content"

COMMANDS_PAGE = CONTENT_DIR / "reference/commands/index.md"
INSTALL_PAGE = CONTENT_DIR / "install.md"
HEALTH_PAGE = CONTENT_DIR / "guides/troubleshooting/diagnose-with-repro-health.md"
LLMS_TXT = ROOT / "llms.txt"

DOCS_ORIGIN = "https://docs.reprobuild.com"
AGENT_INTRO = ROOT / "docs/agents/Repro-Intro-for-Agents.md"

# Canonical topic-based agent guides (single source of truth in docs/agents/ and docs/user-guide/).
# Each tuple is: (repo_rel_path, web_md_path, title, description)
AGENT_TOPIC_GUIDES: list[tuple[str, str, str, str]] = [
    (
        "docs/agents/Repro-Intro-for-Agents.md",
        "/agents/intro.md",
        "Reprobuild Intro for Agents (Start Here)",
        "Core architecture keywords, non-interactive CLI rules (`repro exec`, `--json`), binary pair (`repro` + `reprobuild`), and lock-pin refusal guardrails.",
    ),
    (
        "docs/user-guide/idiomatic-reprobuild.md",
        "/agents/idiomatic-reprobuild.md",
        "Idiomatic Reprobuild (Before Editing `repro.nim`)",
        "Action granularity, narrow declared inputs vs `io-mon` observation, collections, non-determinism, and common agent anti-patterns.",
    ),
    (
        "docs/agents/Test-History-And-Timings.md",
        "/agents/test-history-and-timings.md",
        "Test History, Timings, and RunQuota Store",
        "Querying test durations, peak RSS, and exit signals from the host-wide RunQuota observation store.",
    ),
    (
        "docs/agents/Profiling-For-Optimization.md",
        "/agents/profiling-for-optimization.md",
        "Profiling Reprobuild Workloads",
        "Measuring scheduler, cache, and build-action bottlenecks accurately before optimizing.",
    ),
    (
        "docs/agents/Replaces/How-Repro-Replaces-Build-Systems-Like-Bazel-Buck2-BuildXL-and-Tup.md",
        "/agents/replaces/build-systems.md",
        "How Reprobuild Replaces Bazel, Buck2, BuildXL, and Tup",
        "Type-checked DAG actions, `librepro_monitor_shim` hermeticity, and shared-memory action cache index.",
    ),
    (
        "docs/agents/Replaces/How-Repro-Replaces-Environment-and-Service-Managers-Like-Nix-Direnv-Devenv-and-Process-Compose.md",
        "/agents/replaces/environments-and-services.md",
        "How Reprobuild Replaces Nix, direnv, devenv, Spack, Conan, and Process Compose",
        "Clingo-solved package constraints, locked dev-env overlays, and `servicePlaceholder` daemon orchestration.",
    ),
    (
        "docs/agents/Replaces/How-Repro-Replaces-Direnv.md",
        "/agents/replaces/direnv.md",
        "How Reprobuild Replaces direnv (`repro allow` Trust Model)",
        "Zero-bypass environment activation, closure-hash `repro allow` verification, and CI `REPRO_DEV_ENV_AUTO_ALLOW=1`.",
    ),
    (
        "docs/agents/Replaces/How-Repro-Replaces-Task-Runners-Like-Just-and-Make.md",
        "/agents/replaces/task-runners.md",
        "How Reprobuild Replaces Just and Make",
        "Declaring and invoking named automation tasks (`repro tasks`, `repro run`) inside the locked dev environment.",
    ),
    (
        "docs/agents/Replaces/How-Repro-Replaces-Workspace-Managers-Like-Repo-and-Git-Submodules.md",
        "/agents/replaces/workspace-managers.md",
        "How Reprobuild Replaces repo and Git Submodules",
        "Multi-repository manifests (`repro-workspace.toml`, `repos/*.toml`), branch roles, and `repro develop` routing.",
    ),
    (
        "docs/agents/Replaces/How-Repro-Replaces-Local-Infrastructure-Provisioners-Like-Terraform.md",
        "/agents/replaces/infrastructure-provisioners.md",
        "How Reprobuild Replaces Local Terraform and Dotfile Managers",
        "Declarative `home.nim` and `system.nim` state resources, `plan`/`apply`, and atomic generation rollbacks.",
    ),
]


@dataclass
class CliFlag:
    name: str
    kind: str
    help: str


@dataclass
class CliSubcmd:
    name: str
    help: str


@dataclass
class CliCommand:
    domain: str
    name: str
    aliases: list[str]
    help: str
    subcommands: list[CliSubcmd] = field(default_factory=list)
    flags: list[CliFlag] = field(default_factory=list)


# Ordered descriptions for every `repro health` check in gatherHealthChecksOverSettings.
HEALTH_CHECK_SPECS: list[tuple[str, str, str]] = [
    ("binary-cache-producer-key", "Checks whether an unused auto-generated binary-cache producer keypair sits on disk without publisher configuration.", "No"),
    ("install-version", "Reports the running `repro` version and executable path.", "No"),
    ("daemon-mode", "Reports whether the per-user store daemon is running or `repro` is operating in single-user direct mode.", "Yes (starts user daemon)"),
    ("lease-reaper", "Checks whether the daemon's wall-clock lease reaper is completing sweeps over leased ephemeral state.", "No"),
    ("store", "Verifies that the content-addressed store root exists and its SQLite index opens cleanly.", "No"),
    ("direnv", "Checks whether `direnv` is installed and any workspace `.envrc` is trusted.", "Yes (`direnv allow`)"),
    ("workspace", "Verifies that an initialised workspace marker exists at the workspace root.", "No"),
    ("manifest", "Resolves the active workspace project set and checks its manifests.", "Yes (migrates retired state file)"),
    ("root-role-manifests", "Checks that every declared branch role of the workspace root loads its manifests cleanly.", "No"),
    ("siblings", "Checks that every repository declared in the active workspace project set is cloned on disk.", "Yes (clones missing checkouts)"),
    ("vcs-host-auth", "Confirms that a usable `git` binary is resolvable for workspace operations.", "No"),
    ("repository-identities", "Compares declared repository URLs against canonical forge identities to spot renames or redirects.", "No"),
    ("vcs-hooks", "Verifies that managed Git hooks are installed, unshadowed, worktree-safe and contract-compatible across participating repositories.", "Yes (missing, shadowed, path-unsafe)"),
    ("chained-hooks", "Checks that any chained `<hook>.repro-local` scripts name interpreters and executables that exist.", "No"),
    ("hook-configs", "Finds generated pre-commit or prek hooks, in a hook slot or chained behind a managed hook, whose configuration file is gone, so the hook refuses every fire.", "No"),
    ("hook-interpreter", "Verifies that shells on this host resolve the same `repro` binary that wrote the managed Git hooks.", "No"),
    ("certificate-propagation", "Reports certificate store roots, linked library version, `pre-push` carrier status and policy configuration.", "No"),
    ("lock-writer", "Reads the `post-commit` lock-writer trace to surface silent lock-refresh refusals.", "No"),
    ("push-gateway", "Compares participating repositories' push remotes against their enacted test-certificate gate policy.", "No"),
    ("sibling-exact-pins", "Lists informational exact commit pins of workspace siblings across participating project files.", "No"),
    ("toolchain", "Confirms that the platform Git toolchain required by workspace operations is provisioned.", "No"),
    ("certificate-policy", "Reads each participating repository's `repro.lock` certificate policy and validates its branch rules.", "No"),
    ("workspace-ergonomics", "Checks that `workspace-projects.md` exists, is ignored in `.gitignore` and is referenced in `AGENTS.md`.", "Yes"),
    ("workspace-state-file", "Checks `.repro/workspace-state.toml` for retired filenames or misplaced manifest layers.", "Yes (when unskewed)"),
    ("local-settings-file", "Reports when per-user `repro-workspace.local.toml` is accidentally tracked by Git.", "No"),
    ("unpublished-heads", "Warns when participating checkouts sit at local commits that exist on no remote.", "No"),
    ("disjoint-local-branches", "Warns about unpublished local branches that share no merge-base with the repository's mainline.", "No"),
    ("shared-clone-leaves", "Inspects checkouts borrowing from shared bare clones for missing pools, broken refetch chains or stale remote refs.", "Yes (pools, chains, stale remote refs)"),
    ("shared-clone-pack-temporaries", "Finds git pack temporaries that an interrupted repack or fetch abandoned in the host's shared clone pools, which git can never read.", "Yes (removes them)"),
    ("certificate-policy-snapshot", "Warns when a repository's recorded certificate-policy snapshot in `repro.lock` is behind its project file.", "No"),
]


def declared_version() -> str:
    for line in NIMBLE.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            if k.strip() == "version":
                return v.strip().strip('"')
    raise RuntimeError(f"No version found in {NIMBLE}")


def _extract_quoted(text: str) -> str:
    return "".join(re.findall(r'"([^"]*)"', text)).strip()


STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
CONCATENATION = re.compile(r"\s*&\s*")
# What may follow the last literal of a value: the comma before the next
# argument, the colon that opens the body, a closing parenthesis, or the end.
VALUE_END = re.compile(r"\s*(?:[,:)]|$)")


def _string_argument(text: str, name: str) -> str | None:
    """The value of the named string argument ``name = "..." & "..."`` in a
    declaration, or None when the declaration does not pass it.

    The value is the string literals joined by ``&`` that follow ``name =``,
    and it ends at the first token that is neither: the comma before the next
    named argument, or the colon that opens the body. Any other value (a
    constant, a triple-quoted string) is refused, not shortened. Reading every quoted
    string to the end of the declaration instead would append whatever string
    arguments follow, so a command's ``longHelp`` would land in its one-line
    ``help``.
    """
    opener = re.search(rf"(?<![A-Za-z0-9_]){re.escape(name)}\s*=\s*", text)
    if not opener:
        return None
    parts: list[str] = []
    pos = opener.end()
    while True:
        literal = STRING_LITERAL.match(text, pos)
        # A value this reader cannot follow to its end (a constant, a call, a
        # triple-quoted or raw string) stops the run: returning the literals
        # read so far would publish a truncated help.
        if not literal or text.startswith('"', literal.end()):
            raise RuntimeError(
                f"{CLI_DESC}: the value of `{name} =` in `{text[:80]}` is not "
                "made of plain string literals joined by `&`, the only shape "
                "scripts/render_user_docs_generated.py reads"
            )
        parts.append(literal.group(1))
        joiner = CONCATENATION.match(text, literal.end())
        if not joiner:
            # Anything else after the literal (`% args`, `.dedent`) changes the
            # value, so dropping it would publish a different help.
            if not VALUE_END.match(text, literal.end()):
                raise RuntimeError(
                    f"{CLI_DESC}: the value of `{name} =` in `{text[:80]}` "
                    "continues past its string literals; "
                    "scripts/render_user_docs_generated.py reads only plain "
                    "string literals joined by `&`"
                )
            break
        pos = joiner.end()
    return "".join(parts).strip()


def _short_sentence(help_text: str) -> str:
    """Keep index table cells concise while preserving exact meaning."""
    cleaned = re.sub(r"\s+", " ", help_text).strip()
    if "; " in cleaned and len(cleaned) > 120:
        cleaned = cleaned.split("; ", 1)[0]
    if ". " in cleaned and len(cleaned) > 120:
        cleaned = cleaned.split(". ", 1)[0]
    if cleaned and not cleaned.endswith("."):
        cleaned += "."
    return cleaned.replace("|", "\\|")


# `cliUnbound` since the description moved its macro helpers into clispec
# (`1e3153c423`); `unbound` before.
ROOT_BLOCK_OPENER = re.compile(r"^  result = (?:cliUnbound|unbound) quote do:\s*$")


def _root_command_block(all_lines: list[str]) -> list[str]:
    """The lines of the root command list in cli_description.nim, and no others.

    This parser reads the description by indentation: a top-level command is a
    ``subcmd`` at four spaces. Helper procs that build nested subcommand trees
    (the ``repro workspace`` verbs, for one) open their own ``quote do:`` at
    the same four-space indent, so scanning the whole file would publish their
    ``list``/``enable``/``add`` as top-level ``repro`` commands. Only the block
    the root macro returns describes the top level; it runs from its
    ``result = cliUnbound quote do:`` to the first non-blank line indented less
    than four spaces.
    """
    openers = [i for i, line in enumerate(all_lines) if ROOT_BLOCK_OPENER.match(line)]
    if len(openers) != 1:
        raise RuntimeError(
            f"{CLI_DESC}: expected exactly one root command block "
            f"(`result = cliUnbound quote do:`), found {len(openers)}; "
            "update ROOT_BLOCK_OPENER in scripts/render_user_docs_generated.py"
        )
    start = openers[0] + 1
    end = start
    while end < len(all_lines) and (not all_lines[end].strip() or all_lines[end].startswith("    ")):
        end += 1
    return all_lines[start:end]


@dataclass
class CommandGroup:
    title: str
    primary: list[str]
    secondary: list[str]


GROUP_TABLE_OPENER = re.compile(r"^  ReproCommandGroups\* = @\[\s*$", re.M)
GROUP_ENTRY = re.compile(
    r'ReproCommandGroup\(title: "([^"]+)",\s*'
    r"primary: @\[([^\]]*)\],\s*"
    r"secondary: @\[([^\]]*)\]\)"
)


def parse_command_groups(text: str) -> list[CommandGroup]:
    """The ``ReproCommandGroups`` table of cli_description.nim.

    It is how ``repro --help`` organizes the top-level commands: one heading
    per group, the group's ``primary`` commands on the short page and its
    ``secondary`` ones added by ``repro --help-all``. The table is read as
    text, so its shape is fixed: one ``ReproCommandGroup(title: "...",
    primary: @[...], secondary: @[...])`` per group, string literals only,
    closed by ``)]``.
    """
    opener = GROUP_TABLE_OPENER.search(text)
    if not opener:
        raise RuntimeError(
            f"{CLI_DESC}: found no `ReproCommandGroups* = @[` table; update "
            "GROUP_TABLE_OPENER in scripts/render_user_docs_generated.py"
        )
    end = text.find(")]", opener.end())
    if end < 0:
        raise RuntimeError(f"{CLI_DESC}: the ReproCommandGroups table is not closed by `)]`")
    table = text[opener.end() : end + 1]
    groups = [
        CommandGroup(
            title=m.group(1),
            primary=re.findall(r'"([^"]+)"', m.group(2)),
            secondary=re.findall(r'"([^"]+)"', m.group(3)),
        )
        for m in GROUP_ENTRY.finditer(table)
    ]
    if len(groups) != table.count("ReproCommandGroup("):
        raise RuntimeError(
            f"{CLI_DESC}: a ReproCommandGroups entry does not have the shape "
            "GROUP_ENTRY in scripts/render_user_docs_generated.py reads"
        )
    return groups


def parse_cli_commands() -> list[CliCommand]:
    lines = _root_command_block(CLI_DESC.read_text(encoding="utf-8").splitlines())
    # Every command's domain is its ReproCommandGroups group, assigned by
    # group_commands; the `# ---- ... ----` comments in the description only
    # organise the declarations and are not read.
    domain = "General"
    commands: list[CliCommand] = []
    i = 0
    while i < len(lines):
        sub_m = re.match(r'^    subcmd "([^"]+)"', lines[i])
        if not sub_m:
            i += 1
            continue

        name = sub_m.group(1)
        header_lines = [lines[i]]
        while not header_lines[-1].rstrip().endswith(":") and i + 1 < len(lines):
            i += 1
            header_lines.append(lines[i])
        header = " ".join(part.strip() for part in header_lines)

        vis = "shown"
        if "visibility = internal" in header:
            vis = "internal"
        elif "visibility = hidden" in header:
            vis = "hidden"

        help_text = _string_argument(header, "help") or ""

        alias_m = re.search(r"aliases\s*=\s*\[([^\]]+)\]", header)
        aliases = re.findall(r'"([^"]+)"', alias_m.group(1)) if alias_m else []

        subcommands: list[CliSubcmd] = []
        flags: list[CliFlag] = []
        j = i + 1
        while j < len(lines) and not re.match(r"^    (subcmd|# ----)", lines[j]):
            line = lines[j]
            if not help_text and re.match(r'^      help "', line):
                help_lines = [line]
                while j + 1 < len(lines) and lines[j + 1].startswith("        "):
                    j += 1
                    help_lines.append(lines[j])
                help_text = _extract_quoted(" ".join(x.strip() for x in help_lines))

            nested_m = re.match(r'^      subcmd "([^"]+)"', line)
            if nested_m:
                sub_hdr_lines = [line]
                k = j
                while not sub_hdr_lines[-1].rstrip().endswith(":") and k + 1 < len(lines):
                    k += 1
                    sub_hdr_lines.append(lines[k])
                sub_hdr = " ".join(x.strip() for x in sub_hdr_lines)
                if "visibility = internal" not in sub_hdr and "visibility = hidden" not in sub_hdr:
                    sub_help = _string_argument(sub_hdr, "help") or ""
                    if not sub_help and k + 1 < len(lines) and re.match(r'^        help "', lines[k + 1]):
                        hl = [lines[k + 1]]
                        m_idx = k + 1
                        while m_idx + 1 < len(lines) and lines[m_idx + 1].startswith("          "):
                            m_idx += 1
                            hl.append(lines[m_idx])
                        sub_help = _extract_quoted(" ".join(x.strip() for x in hl))
                    subcommands.append(CliSubcmd(name=nested_m.group(1), help=sub_help))
                j = k + 1
                continue

            flag_m = re.match(r"^      (flag|boolFlag)\s+([A-Za-z0-9_]+)\s+is\s+([^\s,:]+)", line)
            if flag_m:
                fkind, raw_fname, ftype = flag_m.group(1), flag_m.group(2), flag_m.group(3)
                kebab = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", raw_fname).lower()
                flines = [line]
                k = j
                while k + 1 < len(lines) and lines[k + 1].startswith("        "):
                    k += 1
                    flines.append(lines[k])
                fjoined = " ".join(x.strip() for x in flines)
                fhelp = _string_argument(fjoined, "help") or ""
                flags.append(CliFlag(name=f"--{kebab}", kind="bool" if fkind == "boolFlag" else ftype, help=fhelp))
                j = k + 1
                continue

            j += 1

        if vis == "shown":
            commands.append(
                CliCommand(
                    domain=domain,
                    name=name,
                    aliases=aliases,
                    help=help_text,
                    subcommands=subcommands,
                    flags=flags,
                )
            )
        i = j
    return commands


def group_commands(commands: list[CliCommand], groups: list[CommandGroup]) -> list[CliCommand]:
    """``commands`` in the order ``repro --help-all`` lists them, each with
    the title of its group as its domain.

    The Nim compiler refuses a table that leaves a shown command out or names
    one that is not shown; this repeats the check so a stale table fails here
    too rather than dropping a command from the page.
    """
    by_name = {cmd.name: cmd for cmd in commands}
    ordered: list[CliCommand] = []
    for group in groups:
        for name in group.primary + group.secondary:
            if name not in by_name:
                raise RuntimeError(f"{CLI_DESC}: ReproCommandGroups lists `{name}`, which is not a shown top-level command")
            by_name[name].domain = group.title
            ordered.append(by_name.pop(name))
    if by_name:
        raise RuntimeError(f"{CLI_DESC}: ReproCommandGroups leaves out {', '.join(sorted(by_name))}")
    return ordered


def render_commands_by_domain(commands: list[CliCommand], groups: list[CommandGroup]) -> str:
    domains: list[str] = []
    by_dom: dict[str, list[CliCommand]] = {}
    for cmd in commands:
        if cmd.domain not in by_dom:
            domains.append(cmd.domain)
            by_dom[cmd.domain] = []
        by_dom[cmd.domain].append(cmd)
    primary = {group.title: group.primary for group in groups}

    out: list[str] = []
    for dom in domains:
        out.append(f"## {dom}")
        out.append("")
        if primary.get(dom):
            listed = ", ".join(f"`{name}`" for name in primary[dom])
            out.append(
                f"`repro --help` lists {listed} under this heading; the rest are listed by `repro --help-all`."
            )
            out.append("")
        out.append("| Command | Subcommands | What it does |")
        out.append("|---|---|---|")
        for cmd in by_dom[dom]:
            label = f"`repro {cmd.name}`"
            if cmd.aliases:
                label += " (" + ", ".join(f"`repro {a}`" for a in cmd.aliases) + ")"
            subs = ", ".join(f"`{s.name}`" for s in cmd.subcommands) if cmd.subcommands else "—"
            out.append(f"| {label} | {subs} | {_short_sentence(cmd.help)} |")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def render_commands_by_name(commands: list[CliCommand]) -> str:
    out = [
        "| Command | Area | What it does |",
        "|---|---|---|",
    ]
    for cmd in sorted(commands, key=lambda c: c.name):
        label = f"`repro {cmd.name}`"
        if cmd.aliases:
            label += " (" + ", ".join(f"`{a}`" for a in cmd.aliases) + ")"
        out.append(f"| {label} | {cmd.domain} | {_short_sentence(cmd.help)} |")
    return "\n".join(out) + "\n"


def extract_installer_sh_help() -> str:
    text = INSTALL_SH.read_text(encoding="utf-8")
    m = re.search(r"cat <<'USAGE'\n(.*?)\nUSAGE", text, flags=re.S)
    if not m:
        raise RuntimeError("Could not find USAGE heredoc in repro-install.sh")
    return "```text\n" + m.group(1).rstrip() + "\n```\n"


def extract_installer_ps1_help() -> str:
    text = INSTALL_PS1.read_text(encoding="utf-8")
    m = re.search(r"param\(\n(.*?)\n\)", text, flags=re.S)
    if not m:
        raise RuntimeError("Could not find param(...) block in repro-install.ps1")
    out = [
        "```text",
        "Usage: .\\repro-install.ps1 [PARAMETERS]",
        "",
        "  -Method <auto|scoop|tarball>   Install method (default: auto; registers Scoop bucket when Scoop is present).",
        "  -Version <VERSION>             Install this exact version instead of the newest.",
        "  -Uninstall                     Remove the package and clean up the shared bucket if unused.",
        "  -BaseUrl <URL>                 Point every fetch at one base URL (default: $env:REPRO_BASE_URL).",
        "  -Domain <DOMAIN>               Repository domain when -BaseUrl is unset (default: metacraft-labs.com).",
        "  -BucketUrl <URL>               Override the Scoop bucket Git URL (default: $env:REPRO_BUCKET_URL).",
        "  -Prefix <PATH>                 Destination directory for -Method tarball.",
        "  -NoCompletion                  Do not set up shell completion (also REPRO_NO_COMPLETION=1).",
        "  -DryRun                        Print the actions that would run; change nothing.",
        "  -Yes                           Accepted for scripting compatibility (the installer never prompts).",
        "```",
    ]
    # Verify every parameter name in the script appears in our rendered block so drift fails --check.
    param_names = re.findall(r"\$([A-Za-z0-9_]+)", m.group(1).split("=", 1)[0] if False else m.group(1))
    declared_params = re.findall(r"\[(?:string|switch)\]\$([A-Za-z0-9_]+)", m.group(1))
    rendered = "\n".join(out)
    for pname in declared_params:
        if f"-{pname}" not in rendered:
            raise RuntimeError(f"repro-install.ps1 parameter -{pname} missing from rendered help")
    return rendered + "\n"


def verify_and_render_health_checks() -> str:
    lines = CLI_SUPPORT.read_text(encoding="utf-8").splitlines()
    # Narrow to the gatherHealthChecks implementation window
    start_idx = next(i for i, l in enumerate(lines) if "proc hookInterpreterSkewCheck(" in l)
    end_idx = next(i for i, l in enumerate(lines[start_idx:], start=start_idx) if "proc gatherHealthChecks(" in l) + 25
    window = "\n".join(lines[start_idx:end_idx])

    code_names: set[str] = set()
    for m in re.finditer(r'(?:name:\s*"([a-z0-9-]+)"|skippedForUnresolvedManifest\("([a-z0-9-]+)")', window):
        code_names.add(m.group(1) or m.group(2))
    for m in re.finditer(r'const name = "([a-z0-9-]+)"', window):
        code_names.add(m.group(1))

    spec_names = {name for name, _, _ in HEALTH_CHECK_SPECS}
    missing_in_docs = sorted(code_names - spec_names)
    extra_in_docs = sorted(spec_names - code_names)
    if missing_in_docs or extra_in_docs:
        raise RuntimeError(
            f"Health check mismatch vs repro_cli_support.nim: missing={missing_in_docs}, extra={extra_in_docs}"
        )

    out = [
        "| Check | What it inspects | Safe `--fix` |",
        "|---|---|---|",
    ]
    for name, desc, fixable in HEALTH_CHECK_SPECS:
        out.append(f"| `{name}` | {desc} | {fixable} |")
    return "\n".join(out) + "\n"


def replace_generated_region(text: str, tag: str, body: str) -> str:
    begin = f"<!-- generated:begin {tag} -->"
    end = "<!-- generated:end -->"
    if begin not in text:
        raise RuntimeError(f"Missing region marker: {begin}")
    start = text.index(begin) + len(begin)
    stop = text.index(end, start)
    return text[:start] + "\n" + body + text[stop:]


@dataclass
class DocPageMeta:
    rel_path: str
    url: str
    title: str
    description: str
    order: int


def parse_docs_pages() -> list[DocPageMeta]:
    pages: list[DocPageMeta] = []
    for path in sorted(CONTENT_DIR.rglob("*.md")):
        rel = path.relative_to(CONTENT_DIR).as_posix()
        raw = path.read_text(encoding="utf-8").splitlines()
        title = path.stem
        desc = ""
        order = 999
        if raw and raw[0].strip() == "---":
            for line in raw[1:]:
                if line.strip() == "---":
                    break
                if line.startswith("title:"):
                    title = line.split(":", 1)[1].strip().strip('"')
                elif line.startswith("description:"):
                    desc = line.split(":", 1)[1].strip().strip('"')
                elif line.startswith("order:"):
                    try:
                        order = int(line.split(":", 1)[1].strip())
                    except ValueError:
                        pass
        if rel == "index.md":
            route = "/index.md"
        elif rel.endswith("/index.md"):
            route = "/" + rel[: -len("/index.md")] + ".md"
        else:
            route = "/" + rel
        pages.append(
            DocPageMeta(
                rel_path=rel,
                url=f"{DOCS_ORIGIN}{route}",
                title=title,
                description=desc,
                order=order,
            )
        )
    return pages


def _extract_h2_section(md_text: str, heading_title: str) -> str:
    """Extract the body of `## <heading_title>` from a canonical Markdown file."""
    marker = f"## {heading_title}"
    lines = md_text.splitlines()
    out: list[str] = []
    inside = False
    for line in lines:
        if line.strip() == marker:
            inside = True
            continue
        if inside and line.startswith("## "):
            break
        if inside:
            out.append(line)
    return "\n".join(out).strip()


def _strip_frontmatter(md_text: str) -> str:
    lines = md_text.splitlines()
    if lines and lines[0].strip() == "---":
        for idx in range(1, len(lines)):
            if lines[idx].strip() == "---":
                return "\n".join(lines[idx + 1 :]).strip()
    return md_text.strip()


def render_llms_txt(pages: list[DocPageMeta], version: str, *, local_repo: bool) -> str:
    """Render the topic-based `llmstxt.org` router from canonical docs/agents/ + docs/users/ sources."""
    by_rel = {p.rel_path: p for p in pages}
    intro_text = AGENT_INTRO.read_text(encoding="utf-8")
    arch_body = _extract_h2_section(intro_text, "Architecture & Grepable Keywords")
    cli_rules_body = _extract_h2_section(intro_text, "Non-Interactive CLI Execution for Agents")

    def item(p: DocPageMeta) -> str:
        loc_note = f" (local checkout: `docs/users/content/{p.rel_path}`)" if local_repo else ""
        return f"- [{p.title}]({p.url}): {p.description}{loc_note}"

    def agent_item(repo_rel: str, web_md: str, title: str, desc: str) -> str:
        loc_note = f" (local checkout: `{repo_rel}`)" if local_repo else ""
        return f"- [{title}]({DOCS_ORIGIN}{web_md}): {desc}{loc_note}"

    def group(prefix: str) -> list[DocPageMeta]:
        matched = [
            p for p in pages
            if p.rel_path.startswith(prefix)
            and p.rel_path != f"{prefix}index.md"
            and not (p.rel_path.endswith("/index.md") and p.rel_path != "reference/commands/index.md")
        ]
        return sorted(matched, key=lambda x: (x.order, x.rel_path))

    lines: list[str] = [
        "# Reprobuild",
        "",
        f"> Reprobuild (`repro`, v{version}, Apache-2.0) combines BuildXL's monitored automatic dependency tracking, Nix's pinned toolchains in a content-addressed store with atomic generations, and Terraform's plan-and-apply state reconciliation into one compile-time-checked Nim DSL (`repro.nim`, `home.nim`, `system.nim`) across Linux, macOS and Windows. Every link below resolves to a standalone Markdown (`.md`) topic file so an agent can load only the topic its current task requires.",
        "",
        arch_body,
        "",
        "**Non-interactive CLI rules for agents:**",
        "",
        cli_rules_body,
        "",
        "## Agent Topic Guides",
        "",
        *[agent_item(*entry) for entry in AGENT_TOPIC_GUIDES],
        "",
        "## Getting Started",
        "",
        item(by_rel["index.md"]),
        item(by_rel["install.md"]),
        item(by_rel["tutorials/first-build.md"]),
        "",
        "## Concepts and Architecture",
        "",
        *[item(p) for p in group("concepts/")],
        "",
        "## How-To Guides",
        "",
        *[item(p) for p in group("guides/")],
        "",
        "## Coming From Other Tools",
        "",
        *[item(p) for p in group("coming-from/")],
        "",
        "## Reference",
        "",
        *[item(p) for p in group("reference/")],
        "",
        "## Optional",
        "",
        f"- [Complete Assembled Corpus (llms-full.txt)]({DOCS_ORIGIN}/llms-full.txt): Build-generated concatenation of all agent topic guides and user documentation pages for offline RAG indexers.",
        "- [Product & Commercial Offerings (reprobuild.com/llms.txt)](https://reprobuild.com/llms.txt): Hosted Binary Cache, CI Runners, Build Cloud, and EU Cyber Resilience Act (CRA) compliance solutions.",
        "- [GitHub Repository](https://github.com/metacraft-labs/reprobuild): Source code, release archives, issue tracker and Apache-2.0 licence.",
        "",
    ]
    return "\n".join(lines)


def _rewrite_agent_guide_links_for_web(md_text: str, repo_rel: str, pages: list[DocPageMeta]) -> str:
    """Rewrite intra-repo Markdown links inside docs/agents/* to published `.md` URLs on docs.reprobuild.com."""
    mapping = {r_rel: f"{DOCS_ORIGIN}{w_md}" for r_rel, w_md, _, _ in AGENT_TOPIC_GUIDES}
    for p in pages:
        mapping[f"docs/users/content/{p.rel_path}"] = p.url
    src_dir = (ROOT / repo_rel).parent

    def repl(match: re.Match[str]) -> str:
        label, target = match.group(1), match.group(2)
        if target.startswith(("http://", "https://", "#", "mailto:")):
            return match.group(0)
        anchor = ""
        path_part = target
        if "#" in target:
            path_part, frag = target.split("#", 1)
            anchor = f"#{frag}"
        resolved = (src_dir / path_part).resolve()
        try:
            rel_to_root = resolved.relative_to(ROOT).as_posix()
        except ValueError:
            return match.group(0)
        if rel_to_root in mapping:
            return f"[{label}]({mapping[rel_to_root]}{anchor})"
        return f"[{label}](https://github.com/metacraft-labs/reprobuild/blob/dev/{rel_to_root}{anchor})"

    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", repl, md_text)


def emit_web_llms_bundle(public_dir: pathlib.Path, staged_content_dir: pathlib.Path, pages: list[DocPageMeta], version: str) -> None:
    """Publish `/agents/**/*.md`, `/llms.txt` and `/llms-full.txt` into `public_dir` from single-source files."""
    # 1. Copy canonical agent topic guides into `public/agents/...`
    full_sections: list[str] = [
        "# Reprobuild — Complete Assembled Documentation Corpus",
        "",
        f"> Generated at build time from canonical Markdown sources (`v{version}`). Prefer `{DOCS_ORIGIN}/llms.txt` to fetch individual `.md` topic files on demand.",
        "",
    ]

    for repo_rel, web_md, title, desc in AGENT_TOPIC_GUIDES:
        raw = (ROOT / repo_rel).read_text(encoding="utf-8")
        rewritten = _rewrite_agent_guide_links_for_web(_strip_frontmatter(raw), repo_rel, pages) + "\n"
        if re.search(r"\b[a-z0-9-]+-(?:specs|pm)/", rewritten):
            raise RuntimeError(f"Public boundary violation: {repo_rel} references a private specification repository")
        out_path = public_dir / web_md.lstrip("/")
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(rewritten, encoding="utf-8")

        full_sections.extend([
            "---",
            "",
            f"## {title}",
            "",
            f"URL: {DOCS_ORIGIN}{web_md}",
            f"Description: {desc}",
            "",
            rewritten.strip(),
            "",
        ])

    # 2. Append staged user-docs Markdown pages (already interpolated with version + generated CLI/health tables)
    for p in pages:
        staged_file = staged_content_dir / p.rel_path
        src_file = staged_file if staged_file.exists() else (CONTENT_DIR / p.rel_path)
        body = _strip_frontmatter(src_file.read_text(encoding="utf-8"))
        full_sections.extend([
            "---",
            "",
            f"## {p.title}",
            "",
            f"URL: {p.url}",
            f"Description: {p.description}",
            "",
            body,
            "",
        ])

    # 3. Write web `llms.txt` and assembled `llms-full.txt`
    (public_dir / "llms.txt").write_text(render_llms_txt(pages, version, local_repo=False), encoding="utf-8")
    (public_dir / "llms-full.txt").write_text("\n".join(full_sections), encoding="utf-8")


def update_or_check(path: pathlib.Path, wanted: str, check: bool, stale: list[str]) -> None:
    current = path.read_text(encoding="utf-8") if path.exists() else ""
    if current != wanted:
        if check:
            stale.append(str(path.relative_to(ROOT)))
        else:
            path.write_text(wanted, encoding="utf-8")


def main(argv: list[str]) -> int:
    version = declared_version()
    pages = parse_docs_pages()

    if len(argv) >= 3 and argv[0] == "--emit-web-llms":
        public_dir = pathlib.Path(argv[1]).resolve()
        staged_dir = pathlib.Path(argv[2]).resolve()
        emit_web_llms_bundle(public_dir, staged_dir, pages, version)
        return 0

    check = "--check" in argv
    groups = parse_command_groups(CLI_DESC.read_text(encoding="utf-8"))
    commands = group_commands(parse_cli_commands(), groups)
    stale: list[str] = []

    cmd_text = COMMANDS_PAGE.read_text(encoding="utf-8")
    cmd_wanted = replace_generated_region(
        cmd_text, "cli-reference index by=domain", render_commands_by_domain(commands, groups)
    )
    cmd_wanted = replace_generated_region(cmd_wanted, "cli-reference index by=name", render_commands_by_name(commands))
    update_or_check(COMMANDS_PAGE, cmd_wanted, check, stale)

    inst_text = INSTALL_PAGE.read_text(encoding="utf-8")
    inst_wanted = replace_generated_region(inst_text, "installer-help sh", extract_installer_sh_help())
    inst_wanted = replace_generated_region(inst_wanted, "installer-help pwsh", extract_installer_ps1_help())
    update_or_check(INSTALL_PAGE, inst_wanted, check, stale)

    health_text = HEALTH_PAGE.read_text(encoding="utf-8")
    health_wanted = replace_generated_region(health_text, "cli-reference health checks", verify_and_render_health_checks())
    update_or_check(HEALTH_PAGE, health_wanted, check, stale)

    update_or_check(LLMS_TXT, render_llms_txt(pages, version, local_repo=True), check, stale)

    if stale:
        for rel in stale:
            print(f"render_user_docs_generated: {rel} is stale; run python3 scripts/render_user_docs_generated.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
