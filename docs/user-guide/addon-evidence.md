# Add-on mode: evidence that leaves the host

An add-on host records what it does: every apply, every refusal, every
rollback and quarantine, every boot-time re-assertion, every apt hook run
and every deploy-agent tick. Each record is written on the host and shipped
to an **Evidence sink** on another host, where the add-on's detectors run.
A record that reached the sink stays there even if the host is later taken
over: the sink only ever accepts appends.

## The sink

The sink is `repro-evidence-sink`, shipped with Reprobuild. Run it on a host
other than the add-on hosts:

```sh
repro-evidence-sink serve --dir /var/lib/evidence/store \
  --identity /var/lib/evidence/identity --anchors /var/lib/evidence/anchors \
  --checkpoint-key /var/lib/evidence/checkpoint-key --bind <address> --port <port>
```

It accepts appends only. It has no command that lists, reads, overwrites
or deletes a record over the network. It chains every record with a hash
and signs the head after every batch. It also stamps each record with the
identity of the host that sent it, taken from that host's TLS credential.
You read the store on the sink host itself (`repro-evidence-sink read`,
`verify`, `addon-check`).

## Giving a host a sink

At bootstrap, add the sink's address and its CA certificate (the sink's
`identity/host-ca.crt`) to both the preflight and the bootstrap command:

```sh
repro system addon preflight ... --evidence-sink 10.0.0.5:7443 \
  --evidence-sink-ca /root/evidence-sink.crt
repro system addon bootstrap --plan <digest> ... --evidence-sink 10.0.0.5:7443 \
  --evidence-sink-ca /root/evidence-sink.crt
```

To give a host that was bootstrapped without a sink one, run:

```sh
repro system addon evidence-enrol --evidence-sink 10.0.0.5:7443 \
  --evidence-sink-ca /root/evidence-sink.crt
```

Either way, the host gets two keys of its own. Neither is ever reused or
overwritten; `evidence-enrol` refuses a host that already has either one.

- **The attestation key** (`/var/lib/repro/agent/attestation.key`). It
  signs a statement of what the add-on activated in every record. The
  statement names its scope and what it does not cover: the kernel, the
  bootloader and the distribution's packages. It is not an attestation of
  the host.
- **The sink write credential** (`/var/lib/repro/evidence/host-ca.crt` and
  its key). Copy the certificate into the sink's `--anchors` directory to
  let the host append. Remove it from there to revoke that host alone.
  Until you copy it, records wait on the host.

To check the credential from the host, run
`repro system addon evidence-credential-check`. An append must be
acknowledged, and a list, a read, an overwrite and a delete must each be
refused.

## The deploy agent's egress observer

On a host that runs the deploy agent and ships to a sink, the add-on
installs one nftables table of its own, `inet repro_addon_egress`. The table
counts and logs every packet the agent's network-facing fetch unit sends to
an address it is not allowed to reach. The unit's own filter still refuses
those packets; the table only makes the refusals visible. After each fetch,
a check turns every new refused destination into a record. The add-on
touches no other table. Uninstall removes this one. Bootstrap refuses
(`EAddOnEgressObserverUnavailable`) a base that has no `nft`, or whose kernel
lacks the `socket cgroupv2` match, rather than running without the
observer.

## Running the detectors

On the sink host, run:

```sh
repro-evidence-sink addon-check --dir /var/lib/evidence/store \
  --hosts hosts.txt --manifests /var/lib/evidence/published \
  --deploy-signers deploy-signers.anchors
```

`hosts.txt` lists one enrolled host per line: its host id (printed by
bootstrap or `evidence-enrol`) and its deploy-agent target. `--manifests`
is a directory of the manifests the producer published. The command prints
a status for each detector of each host (`live-idle`, `live-detecting`,
`silent` or `never-reported`) and one `ALERT` line for each finding. It
exits 1 when there is at least one alert. The findings are:

- every refusal, rollback, re-assert drift, apt hook finding and refused
  connection a host recorded;
- a host that stopped reporting: no tick, no shipping heartbeat, no
  re-assertion for a boot, or no apt hook record after a dpkg run;
- a signed statement that does not verify, a generation that changed
  between records, or a generation that no published manifest produced;
- a host still behind the producer's latest manifest after that manifest's
  maximum age.
