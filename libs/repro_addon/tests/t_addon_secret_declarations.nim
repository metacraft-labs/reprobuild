## The profile surface of add-on secrets (ReproOS Add-On Mode spec §8.3,
## §10.3): the ``secrets.secretFile`` declaration and a unit's
## ``credentials``, in the canonical text and through the DSL.
##
## - a declaration parses, round-trips through ``renderProfileText``, and
##   is not a resource (no address, nothing for a driver);
## - ``credentials`` render as ``LoadCredential=<n>:/run/repro/secrets/
##   <service>/<n>`` at the end of ``[Service]``, with the unit ordered
##   after the boot-time secrets step;
## - refused: an undeclared credential, a credential of another service's
##   secret, a template unit, a name that is not one safe path segment, a duplicate
##   declaration, a field the stanza does not know (no secret value can
##   be written into a profile);
## - the DSL constructors (``secretFile``, ``systemdSystemUnit(credentials
##   = ...)``) reach the same ``SystemProfile`` through the adapter.
##
## *Mocking.* None: the real parser, renderer and adapter.

import std/[strutils, unittest]

import repro_infra
import repro_infra/intent
import repro_profile
import repro_profile_compile/adapter_system

const Unit = "[Unit]\nDescription=web\n\n[Service]\nExecStart=/bin/true\n\n" &
             "[Install]\nWantedBy=multi-user.target\n"

proc profileText(credentials: string; decls: string): string =
  decls & "\nsystemd.systemUnit {\n  name = \"web.service\"\n  content = \"" &
    Unit & "\"\n" & credentials & "}\n"

const OneDecl = "secrets.secretFile {\n  service = \"web\"\n  name = \"token\"\n}\n"

suite "secrets.secretFile and credentials":
  test "a declaration parses, is not a resource, and round-trips":
    let p = parseSystemProfile(profileText("  credentials = [\"token\"]\n", OneDecl))
    check p.secretFiles == @[SecretFileDecl(service: "web", name: "token")]
    check p.resources.len == 1
    check p.resources[0].suCredentials == @["token"]
    let again = parseSystemProfile(renderProfileText(p))
    check again.secretFiles == p.secretFiles
    check again.resources[0].suCredentials == @["token"]
    # The editor's stanza walk skips it, as it skips the addOn stanza.
    check systemProfileStanzaLineSpans(profileText("", OneDecl)).len == 1

  test "credentials render as LoadCredential= in [Service], after the boot secrets unit":
    let p = parseSystemProfile(profileText("  credentials = [\"token\"]\n", OneDecl))
    let c = renderedSystemUnitContent(p.resources[0])
    check "LoadCredential=token:/run/repro/secrets/web/token" in c
    # Ordered after the bounded boot secrets unit, never after the
    # recovery: the unit is wanted by multi-user.target (§7.7).
    check "Wants=repro-addon-secrets.service" in c
    check "After=repro-addon-secrets.service" in c
    check "repro-addon-reassert" notin c
    # In the [Service] section, before [Install].
    let svc = c.find("[Service]")
    let ins = c.find("[Install]")
    let lc = c.find("LoadCredential=")
    check svc < lc and lc < ins
    # The unit's own lines are all still there.
    check "ExecStart=/bin/true" in c and "WantedBy=multi-user.target" in c

  test "a unit without credentials is rendered verbatim":
    let p = parseSystemProfile(profileText("", OneDecl))
    check renderedSystemUnitContent(p.resources[0]) == Unit

  test "refusals":
    # A credential nothing declares.
    expect ESystemProfileInvalid:
      discard parseSystemProfile(profileText("  credentials = [\"other\"]\n", OneDecl))
    # Declared for another service.
    expect ESystemProfileInvalid:
      discard parseSystemProfile(profileText("  credentials = [\"token\"]\n",
        "secrets.secretFile {\n  service = \"db\"\n  name = \"token\"\n}\n"))
    # A template instance.
    expect ESystemProfileInvalid:
      discard parseSystemProfile("secrets.secretFile {\n  service = \"web@1\"\n" &
        "  name = \"t\"\n}\n")
    # Names that are not one safe segment.
    for bad in ["../x", ".hidden", "a/b", "", "x y"]:
      expect ESystemProfileInvalid:
        discard parseSystemProfile("secrets.secretFile {\n  service = \"web\"\n" &
          "  name = \"" & bad & "\"\n}\n")
    # Twice.
    expect ESystemProfileInvalid:
      discard parseSystemProfile(OneDecl & OneDecl)
    # A value field: secrets never appear in a profile.
    expect ESystemProfileInvalid:
      discard parseSystemProfile("secrets.secretFile {\n  service = \"web\"\n" &
        "  name = \"t\"\n  content = \"hunter2\"\n}\n")

  test "the DSL reaches the same profile through the adapter":
    var rs: seq[ResourceIntent]
    secretFile(rs, service = "web", name = "token")
    systemdSystemUnit(rs, name = "web.service", content = Unit,
                      credentials = @["token"])
    var p = ProfileIntent(resources: rs)
    let sp = profileIntentToSystemProfile(p)
    check sp.secretFiles == @[SecretFileDecl(service: "web", name: "token")]
    check sp.resources.len == 1
    check sp.resources[0].suCredentials == @["token"]
    check "LoadCredential=token:/run/repro/secrets/web/token" in
      renderedSystemUnitContent(sp.resources[0])
