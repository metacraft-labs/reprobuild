## Typed resource catalog for the M68 home-scope resource lifecycle.
##
## Per Home-Profile-Resource-Lifecycle.md "Resource Catalog", a
## `Resource` is one of 11 typed constructors. Phase A implements
## the Windows + cross-platform subset (`fs.managedBlock`,
## `windows.registryValue`, `env.userVariable`, `env.userPath`,
## `windows.startup`, `shell.integration`) plus the
## `lifecyclePolicy` enum and the in-memory `ResourceState`. Phase B
## fleshes out the Linux + macOS variants (`linux.gsettings`,
## `systemd.userUnit`, `macos.userDefault`, `launchd.userAgent`).
##
## The on-disk `ResourceBinding` shape lives in
## `repro_home_generations/manifest.nim` (M62 record type, extended
## by M68's manifest_record.nim).

import std/[tables]

import repro_home_generations

type
  ResourceKind* = enum
    ## The variant tag for `Resource`. The string form is what we
    ## serialize into the `ResourceBinding.resourceKind` field of
    ## the activation manifest.
    rkFsManagedBlock = "fs.managedBlock"
    rkWindowsRegistryValue = "windows.registryValue"
    rkEnvUserVariable = "env.userVariable"
    rkEnvUserPath = "env.userPath"
    rkWindowsStartup = "windows.startup"
    rkShellIntegration = "shell.integration"
    rkLinuxGsettings = "linux.gsettings"
    rkSystemdUserUnit = "systemd.userUnit"
    rkMacosUserDefault = "macos.userDefault"
    rkLaunchdUserAgent = "launchd.userAgent"
    rkFsUserFile = "fs.userFile"
      ## M68 home-scope analogue of system-scope `fs.systemFile`
      ## (M69). Writes a whole file at a `~`-relative `$HOME` path
      ## with declared content + POSIX mode. Idempotent: a re-apply
      ## with unchanged content takes the cache-hit no-op via
      ## digest comparison. On Windows, the mode field is RECORDED
      ## but not applied — Windows uses extensions for executable
      ## status, not POSIX permission bits. See the
      ## `Home-Profile-Resource-Lifecycle.md` "`fs.userFile`"
      ## section for the full contract.
    rkVscodeExtension = "vscode.extension"
      ## Post-M83 declarative VS Code extension set. Manages a SET of
      ## marketplace extension IDs (`ms-python.python`, `vscodevim.
      ## vim`, ...) installed via the `code --install-extension`
      ## CLI. When `removeUnknown == false` (the default) the
      ## resource OWNS only its declared subset and leaves other
      ## extensions the user installed out-of-band alone; when
      ## `removeUnknown == true` it converges to STRICT declarative-
      ## set semantics (uninstall extras). An optional `@<version>`
      ## pin on a declared ID forces a specific marketplace version.
    rkLinuxDconfKey = "linux.dconfKey"
      ## M83 step 7 Driver A. Per-user GNOME-stack settings via the
      ## `dconf` CLI (`~/.config/dconf/user`). Writes a single key
      ## (`/org/gnome/...`) to a GVariant literal value (`'prefer-
      ## dark'`, `true`, `42`, `['a', 'b']`). Content-addressed:
      ## re-apply with unchanged value is a no-op via the BLAKE3
      ## digest comparison. Destroy resets the key to its schema
      ## default via `dconf reset`. Linux-only; raises
      ## `ENotImplementedPlatform` on every other platform.
    rkLinuxKdeConfigKey = "linux.kdeConfigKey"
      ## M83 step 7 Driver B. Per-user KDE Plasma settings via the
      ## `kwriteconfig5` / `kwriteconfig6` CLI. Writes a single key
      ## under a `[group]` in `~/.config/<file>` (e.g. `kdeglobals`,
      ## `kwinrc`). The `kdeVersion` field selects the major (5 or
      ## 6); the apply path observes via the matching `kreadconfig`
      ## binary. Destroy passes `--delete` to remove the key.
      ## Linux-only; raises `ENotImplementedPlatform` elsewhere.
    rkHomebrewFormula = "pkg.homebrewFormula"
      ## M83 step 9 Driver A. Per-user macOS Homebrew CLI formula
      ## (`brew install <name>`). The `formulaName` field carries the
      ## formula identifier (e.g. `ripgrep`, `tmux`); the optional
      ## `formulaVersion` field carries a desired version (empty
      ## means "track the tap's latest"); the optional `formulaArgs`
      ## carry extra `brew install` flags (e.g. `--build-from-source`,
      ## `--HEAD`). The apply path is `brew install`; observe is
      ## `brew list --formula --versions <name>`; destroy is
      ## `brew uninstall <name>`. macOS-only; raises
      ## `ENotImplementedPlatform` elsewhere.
    rkHomebrewCask = "pkg.homebrewCask"
      ## M83 step 9 Driver B. Per-user macOS Homebrew Cask
      ## (`brew install --cask <name>`). Casks deliver GUI/binary
      ## applications under `/Applications/` (e.g. `iterm2`,
      ## `firefox`, `visual-studio-code`, `docker`). The `caskName`
      ## field carries the cask identifier; the optional
      ## `caskVersion` field carries a desired version (typically
      ## empty since most casks track LATEST only); the optional
      ## `caskArgs` carry extra `brew install --cask` flags (e.g.
      ## `--no-quarantine`). The apply path is `brew install
      ## --cask`; observe is `brew list --cask --versions <name>`;
      ## destroy is `brew uninstall --cask <name>`. macOS-only;
      ## raises `ENotImplementedPlatform` elsewhere.

  SystemdUnitState* = enum
    ## M83 step 4b: desired runtime state for a `systemd.userUnit`.
    ## `susRunning` is the default; the driver issues `systemctl
    ## --user start` when `is-active != active`. `susStopped`
    ## flips the direction: the driver issues `systemctl --user
    ## stop` when `is-active == active`. The string form is what
    ## a `home.nim` `state = "Running" | "Stopped"` attribute
    ## carries and how the resource parser maps the attribute back
    ## to the enum.
    susRunning = "Running"
    susStopped = "Stopped"

  RegistryValueKind* = enum
    ## The 6 typed value kinds the `windows.registryValue` driver
    ## understands. The string form is what gets serialized into
    ## `ResourceBinding.payloadKind`; the REG_* numeric constant is
    ## used by the Win32 `RegSetValueExW` call.
    rvkString = "string"            ## REG_SZ (1)
    rvkExpandString = "expandString" ## REG_EXPAND_SZ (2)
    rvkBinary = "binary"            ## REG_BINARY (3)
    rvkDword = "dword"              ## REG_DWORD (4)
    rvkMultiString = "multiString"  ## REG_MULTI_SZ (7)
    rvkQword = "qword"              ## REG_QWORD (11)

  LifecyclePolicy* = enum
    ## Per Home-Profile-Resource-Lifecycle.md "Lifecycle Decision
    ## Algorithm". `lpDefault` is the implicit policy: create /
    ## update / destroy as needed. `lpPreventDestroy` refuses
    ## destroys regardless of `--reconcile-drift` /
    ## `--accept-overwrite`. (Phase B activates the enforcement;
    ## Phase A reserves the enum.)
    lpDefault = "default"
    lpPreventDestroy = "preventDestroy"
    lpPreventRecreate = "preventRecreate"

  ResourceDependency* = tuple[kind: string, name: string]
    ## M82 home-scope follow-up: a single `depends_on` edge —
    ## `"kind:name"` parsed into its two components. The match against
    ## another resource in the same profile uses `kind == $resource.kind`
    ## AND `name == resource.address` so the syntax stays uniform
    ## across every home-scope resource kind. Parallels the system-scope
    ## `ResourceDependency` in
    ## `libs/repro_infra/src/repro_infra/profile.nim`; the two will
    ## logically converge once the home + system planners share a
    ## graph module, but today they remain parallel so this PR can
    ## land without touching system-scope code.

  RegistryValuePayload* = object
    ## The typed value the driver writes to a single registry slot.
    ## All kinds collapse to a `kind` + `bytes` representation in
    ## the manifest — but the in-memory form is typed for clarity.
    kind*: RegistryValueKind
    bytes*: seq[byte]
      ## REG_SZ / REG_EXPAND_SZ: UTF-16LE bytes including the trailing
      ##   double-zero terminator.
      ## REG_BINARY: raw bytes.
      ## REG_DWORD: 4 bytes LE.
      ## REG_QWORD: 8 bytes LE.
      ## REG_MULTI_SZ: UTF-16LE entries each terminated by U+0000,
      ##   the whole sequence terminated by a final U+0000.

  Resource* = object
    ## A single resource the apply pipeline must reconcile against
    ## the real world. The address is the stable identity used to
    ## look up the previous binding; the variant carries the
    ## kind-specific desired state.
    ##
    ## `dependsOn` carries the user-declared dependency edges from the
    ## stanza's optional `depends_on = ["kind:name", ...]` attribute
    ## (M82 home-scope follow-up). The home planner combines these
    ## EXPLICIT edges with IMPLICIT edges inferred from the
    ## `home_producer_consumer_map.ProducerConsumerMap` (today empty —
    ## no home-scope producer/consumer pairs are known) to build the
    ## apply dependency graph and topologically order the emitted
    ## actions. Empty seq is the common case — most home resources
    ## have no declared dependencies.
    address*: string
    lifecyclePolicy*: LifecyclePolicy
    dependsOn*: seq[ResourceDependency]
    case kind*: ResourceKind
    of rkFsManagedBlock:
      hostFilePath*: string
      managedBlockId*: string
      managedBlockContent*: string
    of rkWindowsRegistryValue:
      registryKey*: string              ## "HKCU\\Software\\..."
      registryName*: string             ## value name; "" for default
      registryPayload*: RegistryValuePayload
      registryBroadcastChange*: bool    ## post WM_SETTINGCHANGE when true
    of rkEnvUserVariable:
      envVarName*: string
      envVarPayload*: RegistryValuePayload
        ## REG_SZ or REG_EXPAND_SZ.
    of rkEnvUserPath:
      pathEntries*: seq[string]
        ## Directories the resource contributes to the user's PATH.
        ## Pre-existing entries OUTSIDE this list are preserved on
        ## rollback per gate 4's invariant.
      pathHostFilePath*: string
        ## POSIX host rc file that receives the managed PATH block.
        ## Empty on Windows, where the target is HKCU\Environment\Path.
    of rkWindowsStartup:
      startupName*: string              ## Run-key value name.
      startupCommand*: string           ## launch command.
    of rkShellIntegration:
      shellHostFilePath*: string        ## e.g. $PROFILE
      shellBlockId*: string
      shellBlockContent*: string
    of rkLinuxGsettings:
      gsettingsSchema*: string
      gsettingsKey*: string
      gsettingsPath*: string            ## "" unless relocatable.
      gsettingsValueLiteral*: string    ## GVariant literal.
    of rkSystemdUserUnit:
      unitName*: string
      unitContent*: string
      unitEnabled*: bool
      unitState*: SystemdUnitState
        ## M83 step 4b: desired runtime state — `susRunning`
        ## (`systemctl --user start`) or `susStopped` (`systemctl
        ## --user stop`). Default `susRunning`. The driver compares
        ## the desired state to the observed `is-active` result and
        ## issues start/stop only on mismatch.
    of rkMacosUserDefault:
      defaultsDomain*: string
      defaultsKey*: string
      defaultsValueLiteral*: string
      defaultsRestartTarget*: string    ## "" if no killall.
    of rkLaunchdUserAgent:
      launchdLabel*: string
      launchdPlistContent*: string
        ## M83 step 4b: the rendered plist XML the apply pipeline
        ## writes to disk. The driver always re-derives this field
        ## from `launchdProgramArgs` + `launchdRunAtLoad` +
        ## `launchdKeepAlive` via `buildLaunchAgentPlist` so the
        ## bytes on disk are a deterministic function of the typed
        ## fields. The field is retained on the variant to keep the
        ## V1 manifest reader's `unitContent`-style direct-bytes
        ## path working (an empty value means "render from typed
        ## fields"; a non-empty value means "use these exact bytes").
      launchdRunAtLoad*: bool
      launchdProgramArgs*: seq[string]
        ## M83 step 4b: argv-style program arguments. The driver
        ## emits a `<ProgramArguments><array><string>...</string>
        ## </array>` block from this list. Empty is permitted but
        ## yields an empty `<array/>` (an agent with no program is
        ## valid as a SHELL-OUT-only definition; launchd would fail
        ## to start it but the driver itself does not refuse).
      launchdKeepAlive*: bool
        ## M83 step 4b: `<KeepAlive>` value. Default `false` per
        ## the spec. When `true` launchd restarts the agent after
        ## exit; combine with `runAtLoad=true` for a long-lived
        ## service.
    of rkFsUserFile:
      userFileHostPath*: string
        ## `$HOME`-resolved absolute path. The intent-layer parser
        ## accepts `~/...`, `${HOME}/...`, `${USERPROFILE}/...`
        ## prefixes; `resourceFromEntry` expands them against the
        ## per-run home directory BEFORE constructing the resource.
      userFileContent*: string
        ## Whole-file content (verbatim bytes — the driver writes
        ## them in binary mode so Windows CRLF translation does not
        ## introduce constant-false-positive drift).
      userFileMode*: string
        ## POSIX permission octal as a string ("0600", "0644",
        ## "0755", ...). On Windows the field is RECORDED in the
        ## audit binding but the driver does not apply it. The
        ## default applied when the source omits both `mode` and
        ## `executable` is "0644"; when `executable=true` and
        ## `mode` is absent, the default is "0755".
      userFileExecutable*: bool
        ## POSIX-only convenience flag. Mirrors the `executable`
        ## attribute on the source stanza so the audit binding
        ## reflects the operator's intent. When `mode` is also
        ## present, `mode` wins (the driver applies `mode` and
        ## ignores `executable` beyond bookkeeping).
    of rkLinuxDconfKey:
      dconfKey*: string
        ## Slash-prefixed dconf key path (e.g.
        ## `/org/gnome/desktop/interface/color-scheme`). Validated at
        ## parse time to start with `/`.
      dconfValue*: string
        ## GVariant textual literal — opaque to the driver. The
        ## operator picks the form that matches the schema:
        ## `'prefer-dark'` (string), `true`/`false` (bool), bare
        ## decimal (int), `['a', 'b']` (array). The driver writes it
        ## verbatim via `dconf write`.
    of rkHomebrewCask:
      caskName*: string
        ## Homebrew cask identifier (e.g. `iterm2`, `firefox`,
        ## `visual-studio-code`, `docker`). Validated to match
        ## `[a-z0-9][a-z0-9._+@-]*` so the apply path never
        ## interpolates an unsafe name into a `brew install --cask`
        ## command.
      caskVersion*: string
        ## Optional version pin. Casks typically track LATEST only;
        ## an empty value means "accept whatever the tap installed".
        ## A non-empty value that mismatches the installed version
        ## triggers `brew upgrade --cask <name>`.
      caskArgs*: seq[string]
        ## Optional extra args passed to `brew install --cask`
        ## BEFORE the cask name (e.g. `--no-quarantine`,
        ## `--appdir=...`). Each entry must satisfy
        ## `isSafeHomebrewArg` (no shell metacharacters or
        ## whitespace).
    of rkHomebrewFormula:
      formulaName*: string
        ## Homebrew formula identifier (e.g. `ripgrep`, `tmux`,
        ## `node@18`). Validated to match `[a-z0-9][a-z0-9._+-]*` so
        ## the apply path never interpolates an unsafe name into a
        ## `brew install` command. A versioned-formula tap entry
        ## (`<name>@<major>`) is accepted; the `@` and digits are in
        ## the safe charset.
      formulaVersion*: string
        ## Optional version pin. Homebrew's version model is "the
        ## tap declares one version per formula" — pinning to an
        ## arbitrary version against a non-versioned tap is not
        ## supported. An empty value means "accept whatever the tap
        ## installed". A non-empty value that mismatches the
        ## installed version triggers `brew upgrade <name>`.
      formulaArgs*: seq[string]
        ## Optional extra args passed to `brew install` BEFORE the
        ## formula name (e.g. `--build-from-source`, `--HEAD`,
        ## `--ignore-dependencies`). Each entry must satisfy
        ## `isSafeHomebrewArg` (no shell metacharacters or
        ## whitespace).
    of rkLinuxKdeConfigKey:
      kdeFile*: string
        ## Config file basename under `~/.config/` (e.g. `kdeglobals`,
        ## `kwinrc`).
      kdeGroup*: string
        ## KDE config `[group]` name (without the brackets). Nested
        ## groups are not modelled today; the apply path passes the
        ## value as a single `--group <name>` arg.
      kdeKey*: string
        ## The key name inside the group.
      kdeValue*: string
        ## The string value to write. kwriteconfig accepts arbitrary
        ## strings — the driver does not interpret the value (e.g.
        ## numeric keys still take a string `"42"` and KDE applies
        ## the cast when reading).
      kdeVersion*: int
        ## KDE major (5 or 6). Selects between `kwriteconfig5` /
        ## `kreadconfig5` and `kwriteconfig6` / `kreadconfig6`.
        ## Default `6` per the spec.
    of rkVscodeExtension:
      vscodeExtensions*: seq[string]
        ## Declared marketplace extension IDs, optionally with a
        ## `@<version>` pin (e.g. `vscodevim.vim@1.27.0`). The
        ## driver parses each entry into an `ExtensionSpec` (id,
        ## pinnedVersion). Order is insignificant — the canonical
        ## digest sorts by ID.
      vscodeRemoveUnknown*: bool
        ## When true, the apply path uninstalls any extension NOT
        ## in `vscodeExtensions` (strict declarative-set semantics).
        ## When false (the default), the resource only OWNS its
        ## declared subset and leaves other extensions the user
        ## installed out-of-band alone.

  ResourceActionKind* = enum
    ## Output of the lifecycle decision algorithm.
    rakNoOp = "no_op"
    rakCreate = "create"
    rakUpdate = "update"
    rakReplace = "replace"
    rakDestroy = "destroy"
    rakAdopt = "adopt"
    rakDriftBlocked = "drift_blocked"
      ## Default-policy "do not overwrite drifted state"; the
      ## planner emits this so `repro home plan` can list it and
      ## the apply executor can raise `EDrift` with structured
      ## context.

  ResourceAction* = object
    address*: string
    kind*: ResourceActionKind
    resourceKind*: ResourceKind
    summary*: string
      ## Human-readable line for `repro home plan` output.
    driftExpectedHex*: string
      ## Populated for `rakDriftBlocked` / `rakUpdate` (when
      ## `--reconcile-drift` clobbered a drift).
    driftObservedHex*: string

  ObservedState* = object
    ## What the driver saw in the real world when refreshing the
    ## binding. `present == false` means the resource is absent
    ## (e.g. registry value missing, file missing). `digest` is the
    ## BLAKE3-256 over the canonical bytes (the `payloadBytes` the
    ## driver would record on write).
    present*: bool
    digest*: Digest256
    rawBytes*: seq[byte]
      ## The bytes used to compute `digest`. Retained so the apply
      ## executor can produce a fresh `ResourceBinding` without
      ## re-querying the driver.

  RecordedBinding* = object
    ## In-memory view of a previously recorded ResourceBinding
    ## record. Populated by the manifest_record loader from the M62
    ## activation manifest.
    address*: string
    kind*: ResourceKind
    resourceId*: string
    preWriteDigest*: Digest256
    hasPreWriteDigest*: bool
    postWriteDigest*: Digest256
    payloadKind*: string
    payloadBytes*: seq[byte]
    lifecyclePolicy*: LifecyclePolicy

  ResourceState* = object
    ## Composite "plan input" for one resource: what the previous
    ## generation recorded (if anything) plus what the real world
    ## currently looks like.
    address*: string
    desired*: Resource
    hasDesired*: bool
    observed*: ObservedState
    recorded*: RecordedBinding
    hasRecorded*: bool

  DesiredSet* = object
    ## A collection of resources the apply pipeline plans to
    ## reconcile. Indexed by address for lookup; the spec's
    ## resource-address rules forbid duplicates.
    resources*: OrderedTable[string, Resource]

# ---------------------------------------------------------------------------
# DesiredSet helpers.
# ---------------------------------------------------------------------------

proc initDesiredSet*(): DesiredSet =
  result.resources = initOrderedTable[string, Resource]()

proc add*(set: var DesiredSet; r: Resource) =
  ## Add a desired resource. Duplicates by `address` are silently
  ## replaced — the planner already deduplicates upstream; callers
  ## that want explicit collision detection must check `address in
  ## set.resources` before adding.
  set.resources[r.address] = r

proc len*(set: DesiredSet): int = set.resources.len

# ---------------------------------------------------------------------------
# Kind <-> string helpers.
# ---------------------------------------------------------------------------

proc resourceKindFromString*(s: string): ResourceKind =
  case s
  of $rkFsManagedBlock: rkFsManagedBlock
  of $rkWindowsRegistryValue: rkWindowsRegistryValue
  of $rkEnvUserVariable: rkEnvUserVariable
  of $rkEnvUserPath: rkEnvUserPath
  of $rkWindowsStartup: rkWindowsStartup
  of $rkShellIntegration: rkShellIntegration
  of $rkLinuxGsettings: rkLinuxGsettings
  of $rkSystemdUserUnit: rkSystemdUserUnit
  of $rkMacosUserDefault: rkMacosUserDefault
  of $rkLaunchdUserAgent: rkLaunchdUserAgent
  of $rkFsUserFile: rkFsUserFile
  of $rkVscodeExtension: rkVscodeExtension
  of $rkLinuxDconfKey: rkLinuxDconfKey
  of $rkLinuxKdeConfigKey: rkLinuxKdeConfigKey
  of $rkHomebrewFormula: rkHomebrewFormula
  of $rkHomebrewCask: rkHomebrewCask
  else:
    raise newException(ValueError,
      "unknown resource kind tag: '" & s & "'")

proc registryValueKindFromString*(s: string): RegistryValueKind =
  case s
  of $rvkString: rvkString
  of $rvkExpandString: rvkExpandString
  of $rvkBinary: rvkBinary
  of $rvkDword: rvkDword
  of $rvkMultiString: rvkMultiString
  of $rvkQword: rvkQword
  else:
    raise newException(ValueError,
      "unknown registry value kind tag: '" & s & "'")

proc registryValueKindToRegType*(kind: RegistryValueKind): uint32 =
  ## Map the typed enum to the Win32 REG_* numeric constant.
  case kind
  of rvkString: 1'u32
  of rvkExpandString: 2'u32
  of rvkBinary: 3'u32
  of rvkDword: 4'u32
  of rvkMultiString: 7'u32
  of rvkQword: 11'u32

proc registryValueKindFromRegType*(regType: uint32): RegistryValueKind =
  case regType
  of 1'u32: rvkString
  of 2'u32: rvkExpandString
  of 3'u32: rvkBinary
  of 4'u32: rvkDword
  of 7'u32: rvkMultiString
  of 11'u32: rvkQword
  else:
    raise newException(ValueError,
      "unknown REG_TYPE numeric constant: " & $regType)

proc systemdUnitStateFromString*(s: string): SystemdUnitState =
  ## Map a `home.nim` `state = "..."` attribute to the typed enum.
  ## Empty is treated as the default `susRunning` so an omitted
  ## attribute keeps the spec's default. Unknown values raise
  ## `ValueError`; the apply pipeline turns that into a typed
  ## `EUnstructured` with the offending key/value.
  case s
  of $susRunning, "": susRunning
  of $susStopped: susStopped
  else:
    raise newException(ValueError,
      "unknown systemd.userUnit state: '" & s &
      "'; expected 'Running' or 'Stopped'")

proc lifecyclePolicyFromString*(s: string): LifecyclePolicy =
  case s
  of $lpDefault, "": lpDefault
  of $lpPreventDestroy: lpPreventDestroy
  of $lpPreventRecreate: lpPreventRecreate
  else:
    raise newException(ValueError,
      "unknown lifecyclePolicy: '" & s & "'")

# ---------------------------------------------------------------------------
# Dependency-graph helpers — the kind / name pair a `depends_on` entry
# matches against. The home-scope convention is `name == resource.address`
# (the parser-declared stable id), which matches how `home.nim` users
# would naturally name a dependency target (`fs.managedBlock:bashrc`
# refers to a `fs.managedBlock bashrc:` declaration). M82 home-scope
# follow-up.
# ---------------------------------------------------------------------------

proc resourceKindTag*(r: Resource): string =
  ## The string form of the resource's kind — the LEFT half of the
  ## `"kind:name"` pair a `depends_on` entry uses. Matches `$r.kind`
  ## exactly because the enum string values ARE the profile-syntax
  ## kind tags (e.g. `"fs.managedBlock"`); this proc names the
  ## convention.
  $r.kind

proc resourceName*(r: Resource): string =
  ## The "primary name" of the resource — the RIGHT half of the
  ## `"kind:name"` pair a `depends_on` entry uses. Home scope uses the
  ## resource's declaration ADDRESS as the dependency-target name
  ## (every home resource carries an address; addresses are unique
  ## per profile so the kind+address pair is a stable identity).
  r.address

# ---------------------------------------------------------------------------
# Real-world identity derivation.
# ---------------------------------------------------------------------------

proc realWorldIdentity*(r: Resource): string =
  ## Stable string identifying the real-world object the resource
  ## targets. Two `Resource`s with identical identities at the same
  ## generation are a `EResourceConflict`. Persisted as
  ## `ResourceBinding.resourceId`.
  case r.kind
  of rkFsManagedBlock:
    return r.hostFilePath & "#" & r.managedBlockId
  of rkWindowsRegistryValue:
    return r.registryKey & "\\" & r.registryName
  of rkEnvUserVariable:
    return "HKCU\\Environment\\" & r.envVarName
  of rkEnvUserPath:
    when defined(windows):
      return "HKCU\\Environment\\Path"
    else:
      return r.pathHostFilePath & "#repro-home-userpath"
  of rkWindowsStartup:
    return "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\\" &
      r.startupName
  of rkShellIntegration:
    return r.shellHostFilePath & "#" & r.shellBlockId
  of rkLinuxGsettings:
    return "gsettings:" & r.gsettingsSchema & "|" & r.gsettingsPath & "|" &
      r.gsettingsKey
  of rkSystemdUserUnit:
    return "systemd:user:" & r.unitName
  of rkMacosUserDefault:
    return "defaults:" & r.defaultsDomain & ":" & r.defaultsKey
  of rkLaunchdUserAgent:
    return "launchd:user:" & r.launchdLabel
  of rkFsUserFile:
    # Whole-file ownership: the absolute resolved host path uniquely
    # identifies the real-world object. No suffix is appended — the
    # driver owns the file in full (unlike `fs.managedBlock` which
    # owns a SLICE of the file and therefore qualifies the host path
    # with `#<blockId>`).
    return r.userFileHostPath
  of rkVscodeExtension:
    # Singleton per VS Code installation — the resource manages "the
    # set of installed extensions" for the per-user `code` CLI. The
    # identity is fixed; the lifecycle algorithm uses the resource
    # ADDRESS to disambiguate when a profile declares the resource
    # more than once (which it should not — a closed-set parser-time
    # check guards against that).
    return "vscode:extensions"
  of rkLinuxDconfKey:
    # The dconf key path (slash-prefixed) is globally unique within
    # the per-user dconf database. The `dconf:` prefix scopes the
    # identity namespace so it cannot collide with the other home-
    # scope kinds' identities.
    return "dconf:" & r.dconfKey
  of rkLinuxKdeConfigKey:
    # Triple: `<file>:<group>:<key>` uniquely identifies a single
    # writable slot in `~/.config/<file>`. The `kdeVersion` is NOT
    # part of the identity — switching from kwriteconfig5 to
    # kwriteconfig6 still targets the same file (KDE 5 and 6
    # share the config-file format on disk; only the binary name
    # changes).
    return "kde:" & r.kdeFile & ":" & r.kdeGroup & ":" & r.kdeKey
  of rkHomebrewFormula:
    # The formula NAME uniquely identifies the macOS Homebrew slot.
    # Two `pkg.homebrewFormula` resources at the same `formulaName`
    # are a conflict (the spec calls for explicit-only resolution).
    # `formulaVersion` and `formulaArgs` are part of the DESIRED
    # STATE (covered by the digest) but NOT the identity — a
    # version-pin or extra-arg change is an `update`, not a new
    # resource.
    return "homebrew:formula:" & r.formulaName
  of rkHomebrewCask:
    # Parallel to the formula identity: the cask NAME alone
    # uniquely identifies the macOS slot. `caskVersion` and
    # `caskArgs` are desired-state, not identity. The `homebrew:`
    # prefix is shared with the formula kind but the second
    # path segment (`formula:` vs `cask:`) keeps the two
    # namespaces disjoint, so a formula and a cask with the same
    # name do NOT collide.
    return "homebrew:cask:" & r.caskName
