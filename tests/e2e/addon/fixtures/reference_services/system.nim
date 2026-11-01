## The reference services as system activities, written once and realised
## both on an add-on host and on a host realised in full (ReproOS Add-On
## Mode, "one service activity, two realisations").
##
## - ``vaultwarden``: the password server from a store package, its own
##   system account (sysusers), its state directory (tmpfiles), its
##   configuration file under ``/etc/vaultwarden``, the admin token as a
##   credential (never in the profile, never in the environment file),
##   the hardening floor, and a health check.
## - ``ethereum_validator``: an execution client (geth), a consensus client
##   (prysm's beacon node) and a validator client (prysm's validator) for a
##   local test network, each from a store package and under its own
##   account. The validator is ``exclusive``: two instances signing with
##   the same keys is how a validator gets slashed, so a switch stops the
##   old instance and confirms it exited before the new one starts. Its
##   slashing-protection database lives in a state directory declared by a
##   tmpfiles rule at a fixed path, ``/var/lib/ethereum/validator``, which
##   no unit name, closure or generation is part of: a rename, a new
##   closure or a rollback finds the same database.
##
## The store packages are substitute-only build-action edges with pinned
## output digests: the host never builds them, and a cache entry whose
## archive is not the pinned one is refused before extraction. The pins,
## the prefixes and what the validator gate varies (the validator's unit
## name, its prefix and extra configuration) are in
## ``reference_pins.nim``, which the gate writes beside this file.
##
## Hardening: each unit carries the floor spelled out (``Floor`` below):
## ``ProtectSystem=strict``, private ``/tmp`` and devices, no new
## privileges, a ``@system-service`` syscall filter without
## ``@privileged``, no capabilities, ``MemoryDenyWriteExecute=yes`` and
## execution confined to the unit's own store prefix (``NoExecPaths=/``,
## ``ExecPaths=<prefix>``). It is written here rather than inherited
## because the add-on's ``serviceFloor`` default does not exist yet; when
## it does, these lines are what it must render.

import repro_profile

import ./reference_pins

const
  CannotBuildHere = "exit 70"
    ## The edges' argv: a host never builds a reference package, it
    ## substitutes it (keep it stable: it is part of the cache key).

  Floor = "NoNewPrivileges=yes\n" &
    "ProtectSystem=strict\n" &
    "ProtectHome=yes\n" &
    "PrivateTmp=yes\n" &
    "PrivateDevices=yes\n" &
    "ProtectKernelTunables=yes\n" &
    "ProtectKernelModules=yes\n" &
    "ProtectKernelLogs=yes\n" &
    "ProtectControlGroups=yes\n" &
    "ProtectClock=yes\n" &
    "ProtectHostname=yes\n" &
    "RestrictNamespaces=yes\n" &
    "RestrictRealtime=yes\n" &
    "RestrictSUIDSGID=yes\n" &
    "LockPersonality=yes\n" &
    "MemoryDenyWriteExecute=yes\n" &
    "SystemCallArchitectures=native\n" &
    "SystemCallFilter=@system-service\n" &
    "SystemCallFilter=~@privileged\n" &
    "CapabilityBoundingSet=\n" &
    "AmbientCapabilities=\n" &
    "UMask=0077\n" &
    "NoExecPaths=/\n"

const DefaultFamilies = "AF_UNIX AF_INET AF_INET6"

proc confinedTo(prefix, families: string): string =
  ## The floor, with execution allowed in ``prefix`` only and sockets of
  ## ``families`` only.
  Floor & "RestrictAddressFamilies=" & families & "\n" &
    "ExecPaths=" & prefix & "\n"

proc unitText(description, body, prefix: string; after = "";
              families = DefaultFamilies): string =
  "[Unit]\nDescription=" & description & "\n" &
    (if after.len > 0: "After=" & after & "\nWants=" & after & "\n" else: "") &
    "\n[Service]\n" & body & confinedTo(prefix, families) &
    "\n[Install]\nWantedBy=multi-user.target\n"

const
  VaultwardenConfig = "DATA_FOLDER=/var/lib/vaultwarden\n" &
    "ROCKET_ADDRESS=127.0.0.1\n" &
    "ROCKET_PORT=8000\n" &
    "WEB_VAULT_ENABLED=false\n" &
    "SIGNUPS_ALLOWED=false\n" &
    "LOG_LEVEL=info\n"

  BeaconConfig = "datadir: /var/lib/ethereum/beacon\n" &
    "accept-terms-of-use: true\n" &
    "min-sync-peers: 0\n" &
    "no-discovery: true\n" &
    "bootstrap-node: []\n" &
    "chain-id: 32382\n" &
    "rpc-host: 127.0.0.1\n" &
    "rpc-port: 4000\n" &
    "http-host: 127.0.0.1\n" &
    "http-port: 3500\n" &
    "p2p-tcp-port: 13000\n" &
    "p2p-udp-port: 12000\n" &
    "p2p-quic-port: 13001\n" &
    "p2p-host-ip: 127.0.0.1\n" &
    "execution-endpoint: http://127.0.0.1:8551\n" &
    "suggested-fee-recipient: \"0x0000000000000000000000000000000000000001\"\n" &
    "interop-eth1data-votes: true\n" &
    "monitoring-host: 127.0.0.1\n" &
    "monitoring-port: 8080\n"

  ValidatorConfig = "datadir: " & ValidatorStateDir & "\n" &
    "wallet-dir: /var/lib/ethereum/validator/wallet\n" &
    "accept-terms-of-use: true\n" &
    "beacon-rpc-provider: 127.0.0.1:4000\n" &
    "beacon-rest-api-provider: http://127.0.0.1:3500\n" &
    "suggested-fee-recipient: \"0x0000000000000000000000000000000000000001\"\n" &
    "monitoring-host: 127.0.0.1\n" &
    "monitoring-port: 8081\n" &
    # Before signing anything, check that none of the keys is live on the
    # network (prysm's doppelganger check, which excludes what this
    # client's own database recorded): the one guard against the same keys
    # on a second host, which no switch on this host can see.
    "enable-doppelganger: true\n"

proc credentialServiceName(unit: string): string =
  ## The secrets service a unit loads from: its name without `.service`.
  unit[0 ..< unit.len - ".service".len]

profile "referenceServices":
  addOn:
    managedEtcPrefixes:
      "/etc/vaultwarden"
      "/etc/ethereum"

  # The store packages. Action edges carry no activity (the profile macro
  # refuses one inside `activity`), so they are profile-level: every host
  # this profile applies to substitutes all of them, and each activity's
  # units name the prefixes they run from.
  resources:
    inlineExecCall(
      argv = @["/bin/sh", "-c", CannotBuildHere],
      cwd = VaultwardenPrefix,
      outputs = @["bin"],
      requiresElevation = true,
      address = "vaultwarden-prefix",
      commandStatsId = "inlineExecCall",
      substituteOnly = true,
      expectedOutputDigest = VaultwardenDigest)
    inlineExecCall(
      argv = @["/bin/sh", "-c", CannotBuildHere],
      cwd = GethPrefix, outputs = @["bin"], requiresElevation = true,
      address = "geth-prefix", commandStatsId = "inlineExecCall",
      substituteOnly = true, expectedOutputDigest = GethDigest)
    inlineExecCall(
      argv = @["/bin/sh", "-c", CannotBuildHere],
      cwd = PrysmPrefix, outputs = @["bin"], requiresElevation = true,
      address = "prysm-prefix", commandStatsId = "inlineExecCall",
      substituteOnly = true, expectedOutputDigest = PrysmDigest)
    inlineExecCall(
      argv = @["/bin/sh", "-c", CannotBuildHere],
      cwd = TestnetPrefix, outputs = @["share"], requiresElevation = true,
      address = "testnet-prefix", commandStatsId = "inlineExecCall",
      substituteOnly = true, expectedOutputDigest = TestnetDigest)
    # The validator client from a prefix of its own (the same package's
    # tree published under its own path), so a new closure of the
    # validator alone is a change of this one edge and of its unit.
    inlineExecCall(
      argv = @["/bin/sh", "-c", CannotBuildHere],
      cwd = ValidatorPrefix, outputs = @["bin"], requiresElevation = true,
      address = "validator-prefix", commandStatsId = "inlineExecCall",
      substituteOnly = true, expectedOutputDigest = ValidatorDigest)

  activity vaultwarden:
    resources:
      linuxSysusersEntry(name = "vaultwarden", kind = "user",
        description = "Vaultwarden", home = "/var/lib/vaultwarden",
        address = "vaultwardenUser")
      linuxTmpfilesRule(name = "repro-vaultwarden.conf",
        content = "d /var/lib/vaultwarden 0700 vaultwarden vaultwarden -\n",
        address = "vaultwardenState", dependsOn = @["linux.sysusersEntry:vaultwarden"])
      fsSystemFile(path = "/etc/vaultwarden/config.env",
        content = VaultwardenConfig, mode = "0644",
        address = "vaultwardenConfig")
      secretFile(service = "vaultwarden", name = "admin-token",
        address = "vaultwardenAdminToken")
      systemdSystemUnit(name = "vaultwarden.service",
        content = unitText("Vaultwarden (reference activity)",
          "User=vaultwarden\nGroup=vaultwarden\n" &
          "EnvironmentFile=/etc/vaultwarden/config.env\n" &
          "Environment=ADMIN_TOKEN_FILE=%d/admin-token\n" &
          "ExecStart=" & VaultwardenPrefix & "/bin/vaultwarden\n" &
          "WorkingDirectory=/var/lib/vaultwarden\n" &
          "ReadWritePaths=/var/lib/vaultwarden\n" &
          "Restart=on-failure\n",
          VaultwardenPrefix, after = "network-online.target"),
        credentials = @["admin-token"],
        healthCheck = "http://127.0.0.1:8000/alive",
        address = "vaultwardenUnit",
        dependsOn = @["fs.systemFile:/etc/vaultwarden/config.env", "linux.tmpfilesRule:repro-vaultwarden.conf",
                      "linux.sysusersEntry:vaultwarden"])

  activity ethereum_validator:
    resources:
      linuxSysusersEntry(name = "eth-execution", kind = "user",
        description = "Ethereum execution client",
        home = "/var/lib/ethereum/execution", address = "ethExecutionUser")
      linuxSysusersEntry(name = "eth-beacon", kind = "user",
        description = "Ethereum consensus client",
        home = "/var/lib/ethereum/beacon", address = "ethBeaconUser")
      linuxSysusersEntry(name = "eth-validator", kind = "user",
        description = "Ethereum validator client",
        home = "/var/lib/ethereum/validator", address = "ethValidatorUser")
      # The state directories. The validator's holds the slashing-protection
      # database (`validator.db`) and the encrypted wallet: a fixed path,
      # owned by its account, kept across every switch.
      linuxTmpfilesRule(name = "repro-ethereum.conf",
        content = "d /var/lib/ethereum 0755 root root -\n" &
          "d /var/lib/ethereum/execution 0700 eth-execution eth-execution -\n" &
          "d /var/lib/ethereum/beacon 0700 eth-beacon eth-beacon -\n" &
          "d /var/lib/ethereum/validator 0700 eth-validator eth-validator -\n" &
          (if ValidatorStateDir != "/var/lib/ethereum/validator":
             "d " & ValidatorStateDir & " 0700 eth-validator eth-validator -\n"
           else: "") &
          # The operator provisions the encrypted wallet (the keys) as
          # root before the first apply; this hands it to the account.
          "Z /var/lib/ethereum/validator/wallet - eth-validator eth-validator -\n",
        address = "ethState",
        dependsOn = @["linux.sysusersEntry:eth-execution", "linux.sysusersEntry:eth-beacon", "linux.sysusersEntry:eth-validator"])
      fsSystemFile(path = "/etc/ethereum/beacon.yaml", content = BeaconConfig,
        mode = "0644", address = "beaconConfig")
      fsSystemFile(path = "/etc/ethereum/validator.yaml",
        content = ValidatorConfig & ValidatorExtraConfig, mode = "0644",
        address = "validatorConfig")
      # The engine API's shared secret, once per service that loads it.
      secretFile(service = "eth-execution", name = "jwt", address = "gethJwt")
      secretFile(service = "eth-beacon", name = "jwt", address = "beaconJwt")
      secretFile(service = credentialServiceName(ValidatorUnit),
        name = "wallet-password", address = "validatorWalletPassword")

      systemdSystemUnit(name = "eth-execution.service",
        content = unitText("Ethereum execution client (reference activity)",
          "User=eth-execution\nGroup=eth-execution\n" &
          "ExecStartPre=" & GethPrefix & "/bin/geth --datadir " &
          "/var/lib/ethereum/execution init " & TestnetPrefix &
          "/share/ethereum-testnet/genesis.json\n" &
          "ExecStart=" & GethPrefix & "/bin/geth --datadir " &
          "/var/lib/ethereum/execution --networkid 32382 --nodiscover " &
          "--maxpeers 0 --port 30303 --syncmode full --ipcdisable " &
          "--http --http.addr 127.0.0.1 --http.port 8545 " &
          "--authrpc.addr 127.0.0.1 --authrpc.port 8551 " &
          "--authrpc.jwtsecret %d/jwt\n" &
          "ReadWritePaths=/var/lib/ethereum/execution\n" &
          "Restart=on-failure\n", GethPrefix),
        credentials = @["jwt"],
        healthCheck = "tcp:127.0.0.1:8545",
        address = "gethUnit",
        dependsOn = @["linux.tmpfilesRule:repro-ethereum.conf", "linux.sysusersEntry:eth-execution"])
      systemdSystemUnit(name = "eth-beacon.service",
        content = unitText("Ethereum consensus client (reference activity)",
          "User=eth-beacon\nGroup=eth-beacon\n" &
          "ExecStart=" & PrysmPrefix & "/bin/beacon-chain " &
          "--config-file=/etc/ethereum/beacon.yaml " &
          "--chain-config-file=" & TestnetPrefix &
          "/share/ethereum-testnet/config.yml " &
          "--genesis-state=" & TestnetPrefix &
          "/share/ethereum-testnet/genesis.ssz --jwt-secret=%d/jwt\n" &
          "ReadWritePaths=/var/lib/ethereum/beacon\n" &
          "Restart=on-failure\n", PrysmPrefix,
          after = "eth-execution.service",
          # The beacon node lists the host's interfaces at start (prysm's
          # `network.IPAddr`, through netlink) and panics without it.
          families = DefaultFamilies & " AF_NETLINK"),
        credentials = @["jwt"],
        healthCheck = "http://127.0.0.1:3500/eth/v1/node/version",
        address = "beaconUnit",
        dependsOn = @["linux.tmpfilesRule:repro-ethereum.conf", "linux.sysusersEntry:eth-beacon", "fs.systemFile:/etc/ethereum/beacon.yaml"])
      systemdSystemUnit(name = ValidatorUnit,
        content = unitText("Ethereum validator client (reference activity)",
          "User=eth-validator\nGroup=eth-validator\n" &
          "ExecStart=" & ValidatorPrefix & "/bin/validator " &
          "--config-file=/etc/ethereum/validator.yaml " &
          "--chain-config-file=" & TestnetPrefix &
          "/share/ethereum-testnet/config.yml " &
          "--wallet-password-file=%d/wallet-password\n" &
          "ReadWritePaths=/var/lib/ethereum/validator" &
            (if ValidatorStateDir != "/var/lib/ethereum/validator":
               " " & ValidatorStateDir else: "") & "\n" &
          # Time to close the slashing-protection database on SIGTERM
          # before systemd's SIGKILL.
          "TimeoutStopSec=60\n" &
          "Restart=on-failure\n", ValidatorPrefix,
          after = "eth-beacon.service"),
        exclusive = true,
        credentials = @["wallet-password"],
        healthCheck = "http://127.0.0.1:8081/healthz",
        # Empty: the default address, which names the unit, so a rename is
        # a removal and an addition. The validator gate sets it to show a
        # rename that keeps its address is refused.
        address = ValidatorUnitAddress,
        dependsOn = @["linux.tmpfilesRule:repro-ethereum.conf", "linux.sysusersEntry:eth-validator", "fs.systemFile:/etc/ethereum/validator.yaml"])
