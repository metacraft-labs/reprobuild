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
  --checkpoint-key /var/lib/evidence/checkpoint-key \
  --revoked /var/lib/evidence/revoked --bind <address> --port <port>
```

`--revoked` names a file of host ids, one per line, that the sink refuses
at their next frame even while their certificate is still in the anchors
directory.

Every option takes its value either as `--name value` or as
`--name=value`.

It accepts appends only. It has no command that lists, reads, overwrites
or deletes a record over the network. It chains every record with a hash
and signs the head after every batch. It also stamps each record with the
identity of the host that sent it, taken from that host's TLS credential.
You read the store on the sink host itself, for example with
`repro-evidence-sink read --dir /var/lib/evidence/store`.

## Giving a host a sink

At bootstrap, add the sink's address and its CA certificate (the sink's
`identity/host-ca.crt`) to both the preflight and the bootstrap command:

```sh
repro system addon preflight --deploy-signers /root/deploy-signers.anchors \
  --evidence-sink 10.0.0.5:7443 --evidence-sink-ca /root/evidence-sink.crt
repro system addon bootstrap --plan <digest> \
  --deploy-signers /root/deploy-signers.anchors \
  --evidence-sink 10.0.0.5:7443 --evidence-sink-ca /root/evidence-sink.crt
```

Add your other bootstrap options (the deploy agent's `--target` and
`--manifest`, a binary cache) to both commands in the same way.

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
refused: the sink records each refusal and says so. An operation the sink
never received (it went away, or could not be reached) proves nothing
about the credential, and fails the check. The check announces itself to the sink first, so the sink's
detectors list it as the host's `self-test` instead of four alerts. Four
refused operations that were not announced that way still alert.

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
is a directory of the manifests the producer serves. It may hold only the
newest copy of each: the command keeps, in a state file beside the hosts
file (`hosts.txt.check-state`, or `--state <file>`), when it first saw each
published sequence, and counts a host's lag from that. Run it at least once
while each sequence's first copy is served -- for example from a timer
every few minutes. Keep the state file: losing it restarts every count,
and the command reports a missing one as `check-state new`. A state file
it cannot read or write is an alert of its own
(`check-state-unreadable`, `check-state-unwritable`), and an unreadable
one is never overwritten. The command prints
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

Each `ALERT` line reads `ALERT <host id> <detector> <trigger> seq=<n>
<detail>`: the detector's identifier, what triggered it, and the sink
sequence of the record that raised it. One record can raise more than one
alert, each with its own detector and trigger.

A detection you have dealt with stays in the store, and the command keeps
listing it. To mark it handled, acknowledge it by its sink sequence and its
`<detector>/<trigger>`, both as its `ALERT` line prints them:

```sh
repro-evidence-sink ack --dir /var/lib/evidence/store --seq 15 \
  --alert <detector>/<trigger> --operator alice \
  --reason "compromised compiler replaced; host recovered"
```

Any alert that names a sequence can be acknowledged, whatever record
raised it: a refusal, a heartbeat or an operator's record.
The acknowledgement handles that alert only. Another alert the same record
raised (a signature that does not verify, say) stays until you acknowledge
it too.

The running sink appends the acknowledgement to the store under its own
identity. From then on the command prints the alert as a `HANDLED` line,
with who acknowledged it and why, and it no longer counts toward the exit
code. A silence alert names no sequence and cannot be acknowledged: it
clears when the host reports again.

To see what a record captured (the bytes a refusal refused), print its
payload:

```sh
repro-evidence-sink payload --dir /var/lib/evidence/store --seq 15
```

The payload is printed between `BEGIN UNTRUSTED PAYLOAD` and
`END UNTRUSTED PAYLOAD` markers, and every byte outside printable ASCII is
written `\xNN`, because it is whatever the compromised component produced.
Add `--out <file>` to write the raw bytes to a new file instead. The
`read` command lists each record that has a payload with its size.

## Responding to a detection

When the detectors raise an alert that is not explained by something you
did:

1. **Contain the host.** On the host, run

   ```sh
   repro system addon contain --operator alice --reason "refused compile at seq 15"
   ```

   It records the containment and ships the record to the sink first. Then
   it stops the deploy agent's fetch and apply units, and while the
   containment lasts they do not start again, not after a reboot either. The host stays on its current
   generation. The sink's detectors then report the agent as `contained`
   instead of `silent`. A stop that was not recorded this way, or that came
   after the agent had already gone silent, still reads as silence.
2. **Investigate from the sink.** Read the alert's record
   (`repro-evidence-sink read --dir /var/lib/evidence/store`) and its payload
   (`repro-evidence-sink payload --dir /var/lib/evidence/store --seq 15`). A
   refusal record names the copy of what was
   refused that the host keeps (`stagingCopy`, under
   `/var/lib/repro/agent/refused/`) and the profile compiler it ran
   (`compiler`, `compilerSha256`). Copy the staging copy off the host
   before anything else changes.
3. **Fix the cause.** For example, put back the compiler, or have the
   producer publish a corrected manifest.
4. **Re-key if root may have been reached.** If you cannot rule out that
   the attacker became root on the host, its attestation key and its sink
   credential must be treated as compromised. See "Re-keying a host".
5. **Release the host.**

   ```sh
   repro system addon release --operator alice --reason "compiler restored"
   ```

   It records the release, lets the agent's units start again and starts
   its fetch timer.
6. **Close the alerts.** Once the host has applied the next sequence and the
   detectors show it live, acknowledge each alert you dealt with, as shown
   above.

## Altered store objects

Every store object a generation runs from is checked, at every switch,
against the digest recorded when it was realised. An object whose bytes
changed is recovered from a trusted source (the switch's own plan, the
generation's own file bodies, or the apt archives the closure's lock pins)
and the altered copy is kept on the host, readable by root only, under
`/var/lib/repro/system/addon/store-evidence/`. Each entry holds the object
as it was found (`tree/`), a `manifest` of its entries' digests and a
`record` of what was expected and found. The host ships an `addon-store`
record for it: `store-recovered` once the object holds its original bytes
again, its `recoveredFrom` field naming the trusted source. If the host lost power during a recovery, the next switch files
what it had moved aside and ships `store-recovery-interrupted`. At most
eight entries are kept, none older than 90 days.

Uninstalling the add-on removes `/var/lib/repro`, and with it these
entries. So while any exist, `repro system addon uninstall` refuses: it
names each entry and removes nothing. It also names any object a recovery
left in the store when the host lost power, and records each of them,
and each entry whose record was never written, at the sink first.
`--discard-store-evidence` is refused until the sink has acknowledged
those records. Copy the entries off the host, then
run

```sh
repro system addon uninstall --discard-store-evidence
```

If the sink cannot acknowledge them (it is gone, or no longer accepts
this host) and you must remove the add-on anyway, override the refusal
explicitly:

```sh
repro system addon uninstall --discard-unacknowledged-store-evidence
```

Before it removes anything, this writes a record of every object it
discards without the sink having acknowledged it, and of every record
still queued, to
`/var/log/repro-addon/uninstall-<time>-discarded-unshipped.json` (root
only). The record names the public half of the host's attestation key,
and `<record>.sig` beside it holds that key's signature over exactly the
bytes of the record file. Uninstall prints the record's path and text.
Both files stay after uninstall: keep them with the entries you copied
off the host. If the attestation key is missing, or the record cannot be
written, uninstall refuses and removes nothing.

To check a record, on the host or on any machine you copied both files
to, give as `<key>` the attestation key the sink has enrolled for the
host (the one bootstrap printed):

```sh
repro system addon verify-discard-record \
  /var/log/repro-addon/uninstall-20261108T101500Z-discarded-unshipped.json \
  --key <key>
```

It exits 0 and lists the objects only when the signature is over the
file's exact bytes and by that key. A changed byte, another key or an
empty signature is refused.

A host bootstrapped by an older release is brought up to date by its
first switch, or at once with

```sh
repro system addon migrate
```

## Re-keying a host

To replace a host's attestation key and its sink credential together, run
on the host:

```sh
repro system addon evidence-enrol --rekey
```

It creates the next keys beside the current ones. The current attestation
key then signs a hand-over to the new key and the new credential, and the
hand-over is shipped with the current credential. The new keys replace the
old ones only after the sink has acknowledged the hand-over. The command
prints the new credential's host id. On the sink host:

1. copy the new `/var/lib/repro/evidence/host-ca.crt` into the anchors
   directory, and remove the old certificate from it (the sink then refuses
   the old credential at its next connection). On a sink started with
   `--revoked`, also list the old host id in that file, so it is refused at
   its next frame;
2. run the check with `--update-hosts`:
   `repro-evidence-sink addon-check --dir /var/lib/evidence/store --hosts hosts.txt --update-hosts`.
   It follows the signed hand-over: it adds the new host id to the hosts
   file and marks the old line `retired@<sequence>:<new host id>`. A
   hand-over to an id already in the hosts file, or to the same key, is
   refused and alerted.

If the old key may itself be compromised, do not let it vouch for the new
one:

```sh
repro system addon evidence-enrol --rekey --no-handover
```

Then enrol the new host id and key in the hosts file yourself: add a line
for the new id with its key, and add `retired@<sequence>:<new host id>` to
the old line (anywhere after its host id), using the sink's newest sequence
at the moment you decided the key was compromised. The check then refuses
any hand-over signed by the old key after that point, alerts on any record
that still arrives under the old id, and checks the new id's silence. A
retired line with no enrolled successor is itself an alert.
