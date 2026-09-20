## Pinned SEV-SNP material: what it is, where every byte came from, and
## which of it is real.
##
## ## The short version, because this is the thing a reader has to know
##
## **Everything positive here is genuine.** Two attestation reports
## produced by two different AMD EPYC parts, the endorsement certificate
## of each, a third endorsement certificate from a third part of a later
## generation, and AMD's own signing and root certificates for all three
## platform generations — fetched from AMD's key distribution service by
## this repository, and cross-checked against two unrelated open-source
## projects that publish the same bytes.
##
## **One thing here is fabricated, and it is fabricated on purpose**: the
## `Impostor*` bundle. It is a complete, internally valid, correctly
## signed chain that descends from a root this repository generated. It
## exists to be refused. A negative fixture is the one place where making
## the bytes yourself is not merely acceptable but required — an attacker
## mints their own chain, so the test has to.
##
## Nothing in this file was signed by the code the gates exercise.
##
## ## The vendor material, and how it was corroborated
##
## The three `Kds*ChainPem` constants are the verbatim HTTP response
## bodies of
##
##   https://kdsintf.amd.com/vcek/v1/{Milan,Genoa,Turin}/cert_chain
##
## fetched 2026-09-20. Each carries two PEM certificates: the signing key
## for that generation, then the root. The three `Kds*CrlDerHex`
## constants are the verbatim bodies of the sibling `/crl` endpoints,
## fetched in the same session.
##
## One qualification, because "verbatim" has to be true or it is worth
## nothing: the Turin chain is served with CRLF line endings and the
## other two with LF, and a Nim triple-quoted literal in an LF file
## cannot carry the carriage returns. So that one constant is the
## response with its CRs stripped, its own digest is recorded beside it
## next to the service's, and the two certificates it decodes to are
## byte-identical to the served ones either way. Nothing else was
## touched, in any of the six constants.
##
## Corroboration matters more than the fetch, because a single fetch is a
## single point of trust. Two unrelated projects publish what they say is
## the same vendor chain, and both agree with the service **byte for
## byte**:
##
##   | source                                        | sha256 of the Milan chain |
##   |-----------------------------------------------+---------------------------|
##   | the vendor's service, fetched here            | `22e62f8d…5941ce6`        |
##   | google/go-sev-guest `verify/testdata/milan.testcer` @ `260cf497` | identical |
##   | virtee/sev `tests/certs_data/cert_chain_milan` @ `a966d06d`      | identical |
##
## and for Turin, `virtee/sev tests/certs_data/cert_chain_turin` is
## identical to the service's response as well. Three independent
## publishers of the same 4,602 bytes is a much better statement about
## what AMD's root key is than any one of them alone.
##
## ## The reports and the endorsement certificates
##
## | constant | published by | what it is |
## |----------+--------------+------------|
## | `VirteeMilanReportHex` / `VirteeMilanVcekDerHex` | virtee/sev `tests/certs_data/{report_milan.hex,vcek_milan.der}` @ `a966d06d` | one Milan part |
## | `GsgMilanReportHex` / `GsgMilanVcekDerHex` | google/go-sev-guest `verify/testdata/{attestation.bin,vcek.testcer}` @ `260cf497` | a different Milan part |
## | `VirteeTurinVcekDerHex` | virtee/sev `tests/certs_data/vcek_turin.der` @ `a966d06d` | a third part, a later generation |
## | `GsgMilanVlekChainPem` | google/go-sev-guest `verify/testdata/milanvlek.testcer` @ `260cf497` | the vendor's *other* signing key |
##
## These are real chips. What says so is not the filenames: it is that
## every one of them verifies against the key the vendor's own service
## published, and the private halves of those keys exist in exactly one
## place, which is not this repository. Established with an independent
## tool (OpenSSL 3.4.1) before a line of the code under test was written:
##
##   * each endorsement certificate verifies under the signing key, which
##     verifies under the root, which verifies under itself;
##   * each report's signature verifies under **its own** endorsement
##     certificate's P-384 key and **fails** under the other's;
##   * the part identity in each certificate equals the part identity in
##     its report, and the four platform-version components in each
##     certificate equal the four in its report.
##
## The last point is worth reading twice. Two files from two unrelated
## projects, describing two different machines, agree on five independent
## values apiece across a certificate and a binary blob. Nothing
##  fabricates that by accident.
##
## `GsgMilanVlekChainPem`'s root is byte-identical to the Milan root from
## the service, so the vendor's second signing key is anchored at the
## same place as the first. There is **no** VLEK leaf certificate and
## **no** VLEK-signed report in this file: none is published anywhere
## reachable, so the VLEK path is exercised as far as the intermediate
## and no further, and the gates say so rather than implying otherwise.
##
## ## The impostor, in detail, because a negative fixture that is subtly
## ## wrong proves nothing
##
## The four `Impostor*` constants were made by taking the genuine Milan
## root, the genuine signing certificate and a genuine endorsement
## certificate, **substituting fresh key material into each in place**,
## and re-signing. Every key kept its size — RSA-4096 for the two upper
## certificates, P-384 for the leaf — so no length moved and no field
## shifted. The result is byte-identical to the vendor's certificates
## except in the bytes that say whose keys they are:
##
##   | certificate | bytes | differing from the genuine one |
##   |-------------+-------+--------------------------------|
##   | root        | 1,639 | 1,022 (62%) — the modulus and the signature |
##   | signing key | 1,677 | 1,018 (61%) |
##   | endorsement | 1,360 |   604 (44%) |
##
## Same distinguished names, character for character. Same serial
## numbers. Same validity windows. Same extensions, including the
## vendor's own platform-version and part-identity extensions with the
## same values. Same algorithm identifiers. It is, structurally, the
## vendor's chain.
##
## `ImpostorReportHex` completes it: the genuine Milan report's signed
## prefix, re-signed by the impostor endorsement key, so that the report
## verifies too. 96 bytes differ from the genuine report and all 96 are
## inside the signature field.
##
## The whole bundle was checked to be *internally valid* with OpenSSL
## before it was used as a negative: the impostor root verifies under
## itself, the signing certificate under the root, the endorsement
## certificate under the signing key, and the report under the
## endorsement key. That check is the point of the fixture. A chain that
## is refused because it is broken would prove nothing about whether this
## verifier requires the vendor's root; this one is refused only because
## the key at the end of it is not the vendor's.
##
## **What the impostor therefore does and does not prove.** It proves the
## root rule fires, and that it fires when nothing else has anything to
## object to. It does not prove — and cannot — that the pinned keys are
## the right ones. That is what the three-way agreement above is for, and
## the two claims rest on different evidence on purpose.
##
## ## What is missing, so the next agent does not assume otherwise
##
##   * No report was produced on this host or by this organisation. No
##     part in reach supports this technology; these reports were made by
##     somebody else's machines and published.
##   * No VLEK endorsement certificate and no VLEK-signed report.
##   * No Genoa report and no Genoa endorsement certificate — the Genoa
##     root and signing key are pinned, and nothing descends from them
##     here.
##   * No revoked intermediate that can be presented here. Two of the
##     three published revocation lists name nothing; the **Genoa one
##     names serial 020001**, an intermediate the vendor has since
##     replaced — the Genoa chain it serves today carries 020002 — and
##     no project publishes a certificate holding the revoked serial.
##     So the serial reader has a real, non-empty list to read, and the
##     revocation RULE still has no offline input: reaching it needs one
##     list that is both signed by a pinned root and names the serial of
##     the intermediate beside it, and making that pair means holding
##     the vendor's private key.
##   * The vendor's revocation lists expire. `KdsMilanCrlDerHex` states a
##     next-update of 2026-10-04, so every case that consults it fixes
##     its own clock rather than reading the host's. A gate that read the
##     real time would begin failing on a date nobody chose.

const
  # ---- Milan: https://kdsintf.amd.com/vcek/v1/Milan/cert_chain
  #      sha256 22e62f8d2c21a156470145fc75f7b5a377cb053ced3e97f0bd3f8d8ca5941ce6  (4602 bytes)
  KdsMilanChainPem* = """-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIGYzCCBBKgAwIBAgIDAQAAMEYGCSqGSIb3DQEBCjA5oA8wDQYJYIZIAWUDBAIC
BQChHDAaBgkqhkiG9w0BAQgwDQYJYIZIAWUDBAICBQCiAwIBMKMDAgEBMHsxFDAS
BgNVBAsMC0VuZ2luZWVyaW5nMQswCQYDVQQGEwJVUzEUMBIGA1UEBwwLU2FudGEg
Q2xhcmExCzAJBgNVBAgMAkNBMR8wHQYDVQQKDBZBZHZhbmNlZCBNaWNybyBEZXZp
Y2VzMRIwEAYDVQQDDAlBUkstTWlsYW4wHhcNMjAxMDIyMTcyMzA1WhcNNDUxMDIy
MTcyMzA1WjB7MRQwEgYDVQQLDAtFbmdpbmVlcmluZzELMAkGA1UEBhMCVVMxFDAS
BgNVBAcMC1NhbnRhIENsYXJhMQswCQYDVQQIDAJDQTEfMB0GA1UECgwWQWR2YW5j
ZWQgTWljcm8gRGV2aWNlczESMBAGA1UEAwwJQVJLLU1pbGFuMIICIjANBgkqhkiG
9w0BAQEFAAOCAg8AMIICCgKCAgEA0Ld52RJOdeiJlqK2JdsVmD7FktuotWwX1fNg
W41XY9Xz1HEhSUmhLz9Cu9DHRlvgJSNxbeYYsnJfvyjx1MfU0V5tkKiU1EesNFta
1kTA0szNisdYc9isqk7mXT5+KfGRbfc4V/9zRIcE8jlHN61S1ju8X93+6dxDUrG2
SzxqJ4BhqyYmUDruPXJSX4vUc01P7j98MpqOS95rORdGHeI52Naz5m2B+O+vjsC0
60d37jY9LFeuOP4Meri8qgfi2S5kKqg/aF6aPtuAZQVR7u3KFYXP59XmJgtcog05
gmI0T/OitLhuzVvpZcLph0odh/1IPXqx3+MnjD97A7fXpqGd/y8KxX7jksTEzAOg
bKAeam3lm+3yKIcTYMlsRMXPcjNbIvmsBykD//xSniusuHBkgnlENEWx1UcbQQrs
+gVDkuVPhsnzIRNgYvM48Y+7LGiJYnrmE8xcrexekBxrva2V9TJQqnN3Q53kt5vi
Qi3+gCfmkwC0F0tirIZbLkXPrPwzZ0M9eNxhIySb2npJfgnqz55I0u33wh4r0ZNQ
eTGfw03MBUtyuzGesGkcw+loqMaq1qR4tjGbPYxCvpCq7+OgpCCoMNit2uLo9M18
fHz10lOMT8nWAUvRZFzteXCm+7PHdYPlmQwUw3LvenJ/ILXoQPHfbkH0CyPfhl1j
WhJFZasCAwEAAaN+MHwwDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBSFrBrRQ/fI
rFXUxR1BSKvVeErUUzAPBgNVHRMBAf8EBTADAQH/MDoGA1UdHwQzMDEwL6AtoCuG
KWh0dHBzOi8va2RzaW50Zi5hbWQuY29tL3ZjZWsvdjEvTWlsYW4vY3JsMEYGCSqG
SIb3DQEBCjA5oA8wDQYJYIZIAWUDBAICBQChHDAaBgkqhkiG9w0BAQgwDQYJYIZI
AWUDBAICBQCiAwIBMKMDAgEBA4ICAQC6m0kDp6zv4Ojfgy+zleehsx6ol0ocgVel
ETobpx+EuCsqVFRPK1jZ1sp/lyd9+0fQ0r66n7kagRk4Ca39g66WGTJMeJdqYriw
STjjDCKVPSesWXYPVAyDhmP5n2v+BYipZWhpvqpaiO+EGK5IBP+578QeW/sSokrK
dHaLAxG2LhZxj9aF73fqC7OAJZ5aPonw4RE299FVarh1Tx2eT3wSgkDgutCTB1Yq
zT5DuwvAe+co2CIVIzMDamYuSFjPN0BCgojl7V+bTou7dMsqIu/TW/rPCX9/EUcp
KGKqPQ3P+N9r1hjEFY1plBg93t53OOo49GNI+V1zvXPLI6xIFVsh+mto2RtgEX/e
pmMKTNN6psW88qg7c1hTWtN6MbRuQ0vm+O+/2tKBF2h8THb94OvvHHoFDpbCELlq
HnIYhxy0YKXGyaW1NjfULxrrmxVW4wcn5E8GddmvNa6yYm8scJagEi13mhGu4Jqh
3QU3sf8iUSUr09xQDwHtOQUVIqx4maBZPBtSMf+qUDtjXSSq8lfWcd8bLr9mdsUn
JZJ0+tuPMKmBnSH860llKk+VpVQsgqbzDIvOLvD6W1Umq25boxCYJ+TuBoa4s+HH
CViAvgT9kf/rBq1d+ivj6skkHxuzcxbk1xv6ZGxrteJxVH7KlX7YRdZ6eARKwLe4
AFZEAwoKCQ==
-----END CERTIFICATE-----
"""
  #   the two certificates it carries, in the order it carries them:
  #   [0] ASK sha256 67d303bd3905fd38db8b20e0793699870e7fa612eaad5dec358293fd8c0bac1b  (1677 bytes)
  #   [1] ARK sha256 69d063b45344d26a2e94e1f4210de49ef555308287d4c174445c95639a540bcd  (1639 bytes)
  #   Neither is stored separately: the gate base64-decodes the text
  #   above, so what it reads is what the service served.
  # CRL https://kdsintf.amd.com/vcek/v1/Milan/crl
  #   sha256 873efcf8c8cedc28c603cf50acdff8556a704658357a0d9daab297f483deb0df  (866 bytes)
  KdsMilanCrlDerHex* =
      "3082035e30820112020101304106092a864886f70d01010a3034a00f300d06096086" &
      "480165030402020500a11c301a06092a864886f70d010108300d0609608648016503" &
      "0402020500a203020130307b31143012060355040b0c0b456e67696e656572696e67" &
      "310b30090603550406130255533114301206035504070c0b53616e746120436c6172" &
      "61310b300906035504080c024341311f301d060355040a0c16416476616e63656420" &
      "4d6963726f20446576696365733112301006035504030c0941524b2d4d696c616e17" &
      "0d3236303831393134313932335a170d3236313030343030303030305aa02f302d30" &
      "1f0603551d2304183016801485ac1ad143f7c8ac55d4c51d4148abd5784ad453300a" &
      "0603551d14040302010b304106092a864886f70d01010a3034a00f300d0609608648" &
      "0165030402020500a11c301a06092a864886f70d010108300d060960864801650304" &
      "02020500a20302013003820201007d9a62bf596dd4fc63b0daab57acaa176199a5b5" &
      "ebd87cb83737d8c2862ab1a88b113a9ee54b442c622130bb14e911f92b1387ba93f2" &
      "6c529d17d6b11466b85a60843b80b66e92eb75c6d3739641816cb3afacd9343a86d7" &
      "b142b7ff4e11dd7cb46752c6a0a095a025d34e7494e3bdd9971e2ebbcbb84ff46c06" &
      "0a85ee72aa153136c9d39a1873de0e0ada58f112e029d6d29f75829a70035d9c9657" &
      "c9be75433bc25355f3d4375640c93dee8be17d9d4a592697b3db98ea6a1e2fbbd1a6" &
      "ea9cbdd1bbe7c44dd58a64f02d2ea205be2918ecda2c7f892f8f0ecbb97e42adfcd4" &
      "2cf6fba6833776f3fdcc13914e6da9d75af94385f4958e0b61a7b93897fa328a65bb" &
      "eb0688f42cac7c449015c69d77127f1b6ab5d9e568fbb1f9f110eae6cba11e361eac" &
      "1fd42a0851863d2ec78b4caef23154236a1d7beb5e4aa84865376e339511d698f15a" &
      "a638b5ec19d03dfc3ab72f94ef7eb1187393cb8cbdd1f54f2f685ce897ca0104280f" &
      "b2e753303bcd459e8c4697bafcbb261837cb9112219320d204db22163fcf4761d451" &
      "3ea2fd577f4cf2df90c6f189e83a0f0780b6cf5dbdd7642c2c8a305ef541978a12d5" &
      "d566f89717328e0fe13de96dec0d829df46ef80a2bca6e83daf9274352cbe65331f4" &
      "917b6bd78dba8957b5fcfc70cef90716ad92cfafab63b04593b9377bb190aef05230" &
      "5df241bd80d1843d0387c2eb6129c910"

  # ---- Genoa: https://kdsintf.amd.com/vcek/v1/Genoa/cert_chain
  #      sha256 e6ecc853fa56d3170a624d40851f98a1036f974b50204ea69e6aec91d777aca3  (4602 bytes)
  KdsGenoaChainPem* = """-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
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
/wMz1R1BHg==
-----END CERTIFICATE-----
"""
  #   the two certificates it carries, in the order it carries them:
  #   [0] ASK sha256 5464738c1546aed5f2cecf1dc98c5c960a92e8913238a61711bc90ec6e828521  (1677 bytes)
  #   [1] ARK sha256 4c6598d19c18719c5dfd4a7d335f674e5bfe1d8f800cea2cf270c10d103db2f1  (1639 bytes)
  #   Neither is stored separately: the gate base64-decodes the text
  #   above, so what it reads is what the service served.
  # CRL https://kdsintf.amd.com/vcek/v1/Genoa/crl
  #   sha256 31deeb4eef05a1c68d4807f37d8cc3918a966ef32fb02966d53f177cf1c73e72  (890 bytes)
  KdsGenoaCrlDerHex* =
      "308203763082012a020101304106092a864886f70d01010a3034a00f300d06096086" &
      "480165030402020500a11c301a06092a864886f70d010108300d0609608648016503" &
      "0402020500a203020130307b31143012060355040b0c0b456e67696e656572696e67" &
      "310b30090603550406130255533114301206035504070c0b53616e746120436c6172" &
      "61310b300906035504080c024341311f301d060355040a0c16416476616e63656420" &
      "4d6963726f20446576696365733112301006035504030c0941524b2d47656e6f6117" &
      "0d3236303831393134303930315a170d3236313030343030303030305a3016301402" &
      "03020001170d3232313033313132303030305aa02f302d301f0603551d2304183016" &
      "80149f5df9fe0dd8f35ad0331a25ef81294fbe31a85b300a0603551d14040302010a" &
      "304106092a864886f70d01010a3034a00f300d06096086480165030402020500a11c" &
      "301a06092a864886f70d010108300d06096086480165030402020500a20302013003" &
      "820201007a9ae04bee3b67005651b34493ed42fe5657d436df28795ef9a61b3547f8" &
      "d5cb47ad8b5a5f5b0c9b6f35fa85ea904c6859f971c04f21e15c7f6908427944b691" &
      "f5ea14c24fff3179628e6d27e24f7297c619ea9ce18cb52a9c47f531562c6c2e3417" &
      "8b5769c72436130462b93f7b16e1c8d28ad82d55fd92a2dd2e13812221312c395e9c" &
      "a5497c15f43ecc050fcda9253829709621eb4ffcbfdd4a18cabdebb6e197b38ec00a" &
      "8541385b0d5398b5ef60810625d0f5b87f1ac8c237f1a2590e18af225f74a1c75110" &
      "a5a8767cd59ef71d7886f209cc90dc4f1ab6b0868115d2434b680f28cbf4de41b37a" &
      "5304cb23c2c3787e41f1d43874fddf6bee11080a0c3a403bbf827f413a4d8ac35df6" &
      "23e931a382178e532737a1d64eea2a91b80e1fda33113f6296ea4132efcc470e8c4a" &
      "1c66cf65b8cd570a5af671dda27d2050c887dc5c23f27af0678bb42f76810de5d36e" &
      "324765fc141fe5f0eb1a73e5ceaf2b1c72b1c967b5c27bb7a3794a70cae9c38f4836" &
      "5320bbe79518541615f813bd82ff4be36903dcda9d9fe68fbb62e4ba45da27591cff" &
      "7081cca0477262def49d5f0d8664d4490f3fe2ab7f6a4018c32950ae7ebf9ba06753" &
      "b33bb1cae5a33d4672e30bb9e04dd4993b02706dac63cd325c03dd6fee6668b32564" &
      "a11b9b10a878be68f68720062e93070315b7fb027da5ed6eb912c464fca5fffc08b3" &
      "460c02ea7f0a"

  # ---- Turin: https://kdsintf.amd.com/vcek/v1/Turin/cert_chain
  #      This is the ONE response of the three that is not stored here
  #      byte for byte, and the difference is line endings and nothing
  #      else. The service serves Turin with CRLF and Milan and Genoa
  #      with LF; a Nim triple-quoted literal in an LF file cannot hold
  #      the carriage returns, so they are stripped. Both digests, so a
  #      reader can check either statement:
  #        as served      sha256 cc9a52fbed3fbc6e4a0a50149a541a75938f975658909c2a6084767829b36e85  (4676 bytes)
  #        as stored here sha256 3bc97ef895aa1be2150b2e9fb12403f131e80c68fbc9683d2ae465220188dbfe  (4602 bytes)
  #      The two CERTIFICATES are identical either way — base64 ignores
  #      the line breaks — and their digests are below, which is what
  #      the gate actually reads. `virtee/sev`'s copy of this file also
  #      carries CRLF, which is corroboration rather than coincidence:
  #      two projects fetched the same response from the same service.
  KdsTurinChainPem* = """-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
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
zpacMwFusA==
-----END CERTIFICATE-----
"""
  #   the two certificates it carries, in the order it carries them:
  #   [0] ASK sha256 5b77ef5fe7a7a004fd9032668fba9d0fda22f88c4442069a479636a6ae3b3185  (1677 bytes)
  #   [1] ARK sha256 1f084161a44bb6d93778a904877d4819cafa5d05ef4193b2ded9dd9c73dd3f6a  (1639 bytes)
  #   Neither is stored separately: the gate base64-decodes the text
  #   above, so what it reads is what the service served.
  # CRL https://kdsintf.amd.com/vcek/v1/Turin/crl
  #   sha256 49dd3fb3194c43fa7a703f1c67144574b458ca7b23d0a20a270e44678b29cb49  (866 bytes)
  KdsTurinCrlDerHex* =
      "3082035e30820112020101304106092a864886f70d01010a3034a00f300d06096086" &
      "480165030402020500a11c301a06092a864886f70d010108300d0609608648016503" &
      "0402020500a203020130307b31143012060355040b0c0b456e67696e656572696e67" &
      "310b30090603550406130255533114301206035504070c0b53616e746120436c6172" &
      "61310b300906035504080c024341311f301d060355040a0c16416476616e63656420" &
      "4d6963726f20446576696365733112301006035504030c0941524b2d547572696e17" &
      "0d3236303831393134323234355a170d3236313030343030303030305aa02f302d30" &
      "1f0603551d2304183016801464a05f71e30c0a64d83b75e501599e2bee060344300a" &
      "0603551d140403020107304106092a864886f70d01010a3034a00f300d0609608648" &
      "0165030402020500a11c301a06092a864886f70d010108300d060960864801650304" &
      "02020500a20302013003820201002a0334587d886559adc04c97821929b1dfc51d1e" &
      "a7a85e15fdad0f568389a918661f4e76d57764fac81e59fb0e5245e8add83c2990a8" &
      "88ee6638a03f3e11cfe2fe3b0dc21623d0f869e026784cbd145235b2a6c6511453ee" &
      "0984d1ba7b4bcc7caa1fe040332d84b2230a90718a36c57e0e8d18f28459d266024d" &
      "2b21a7f40bfb8b10b141ad4461c0014e7b56f6b8dd43a09ef35fa4b1f798922c9276" &
      "e70e14f416ffbd6ac1d4b73f07dc2d1d25a81e487066af9be35648100dcb14fde61a" &
      "f6210cd6d42bc14e77d77de6571ced8bb5ea91b77ceeb858a46f1b35a758c27f6068" &
      "2f817406bcf50d412d843c08270b4a849ee297a550a97f53ec9903b66203dd0e2384" &
      "06fd7512591dd549f0ff7759646e51ea7c638cbd49d2bbe62f9c596472eb3e500ca5" &
      "8e51b08326a36cd00d639f52f444264843a40572b312bf28dd647a11eba1c12a7105" &
      "f967e80a14a912467a57c92828069bdde294cf55528e11ee548531b3078a90649945" &
      "2022d0967aac89d5dfcee18690bcf9d144b01a24dc67a56ac2541ed52982e31b2660" &
      "fbc4f45d2e83ff12e95e86f1bc0b1abb6fc9cba48d656cbcbb1548e04b9c7168a7fd" &
      "d79019c8f03c913b8b7129b8920d024a1c48b4bb9fd5f5c850568bbd68c84d0b1600" &
      "469dde0ba3f515dabac913750c87be21265ddc2127e1a16c0a29ca3c886d4c64d8dc" &
      "0dada1d51d6bf961c22acae5a27efc37"

  # go-sev-guest verify/testdata/milanvlek.testcer @260cf497
  #   sha256 3098f7e90ee7049b8cf116448d1bdf33b08847b4250bd99507cf73b5c49d3467  (4611 bytes)
  GsgMilanVlekChainPem* = """-----BEGIN CERTIFICATE-----
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
0YPk
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIGYzCCBBKgAwIBAgIDAQAAMEYGCSqGSIb3DQEBCjA5oA8wDQYJYIZIAWUDBAIC
BQChHDAaBgkqhkiG9w0BAQgwDQYJYIZIAWUDBAICBQCiAwIBMKMDAgEBMHsxFDAS
BgNVBAsMC0VuZ2luZWVyaW5nMQswCQYDVQQGEwJVUzEUMBIGA1UEBwwLU2FudGEg
Q2xhcmExCzAJBgNVBAgMAkNBMR8wHQYDVQQKDBZBZHZhbmNlZCBNaWNybyBEZXZp
Y2VzMRIwEAYDVQQDDAlBUkstTWlsYW4wHhcNMjAxMDIyMTcyMzA1WhcNNDUxMDIy
MTcyMzA1WjB7MRQwEgYDVQQLDAtFbmdpbmVlcmluZzELMAkGA1UEBhMCVVMxFDAS
BgNVBAcMC1NhbnRhIENsYXJhMQswCQYDVQQIDAJDQTEfMB0GA1UECgwWQWR2YW5j
ZWQgTWljcm8gRGV2aWNlczESMBAGA1UEAwwJQVJLLU1pbGFuMIICIjANBgkqhkiG
9w0BAQEFAAOCAg8AMIICCgKCAgEA0Ld52RJOdeiJlqK2JdsVmD7FktuotWwX1fNg
W41XY9Xz1HEhSUmhLz9Cu9DHRlvgJSNxbeYYsnJfvyjx1MfU0V5tkKiU1EesNFta
1kTA0szNisdYc9isqk7mXT5+KfGRbfc4V/9zRIcE8jlHN61S1ju8X93+6dxDUrG2
SzxqJ4BhqyYmUDruPXJSX4vUc01P7j98MpqOS95rORdGHeI52Naz5m2B+O+vjsC0
60d37jY9LFeuOP4Meri8qgfi2S5kKqg/aF6aPtuAZQVR7u3KFYXP59XmJgtcog05
gmI0T/OitLhuzVvpZcLph0odh/1IPXqx3+MnjD97A7fXpqGd/y8KxX7jksTEzAOg
bKAeam3lm+3yKIcTYMlsRMXPcjNbIvmsBykD//xSniusuHBkgnlENEWx1UcbQQrs
+gVDkuVPhsnzIRNgYvM48Y+7LGiJYnrmE8xcrexekBxrva2V9TJQqnN3Q53kt5vi
Qi3+gCfmkwC0F0tirIZbLkXPrPwzZ0M9eNxhIySb2npJfgnqz55I0u33wh4r0ZNQ
eTGfw03MBUtyuzGesGkcw+loqMaq1qR4tjGbPYxCvpCq7+OgpCCoMNit2uLo9M18
fHz10lOMT8nWAUvRZFzteXCm+7PHdYPlmQwUw3LvenJ/ILXoQPHfbkH0CyPfhl1j
WhJFZasCAwEAAaN+MHwwDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBSFrBrRQ/fI
rFXUxR1BSKvVeErUUzAPBgNVHRMBAf8EBTADAQH/MDoGA1UdHwQzMDEwL6AtoCuG
KWh0dHBzOi8va2RzaW50Zi5hbWQuY29tL3ZjZWsvdjEvTWlsYW4vY3JsMEYGCSqG
SIb3DQEBCjA5oA8wDQYJYIZIAWUDBAICBQChHDAaBgkqhkiG9w0BAQgwDQYJYIZI
AWUDBAICBQCiAwIBMKMDAgEBA4ICAQC6m0kDp6zv4Ojfgy+zleehsx6ol0ocgVel
ETobpx+EuCsqVFRPK1jZ1sp/lyd9+0fQ0r66n7kagRk4Ca39g66WGTJMeJdqYriw
STjjDCKVPSesWXYPVAyDhmP5n2v+BYipZWhpvqpaiO+EGK5IBP+578QeW/sSokrK
dHaLAxG2LhZxj9aF73fqC7OAJZ5aPonw4RE299FVarh1Tx2eT3wSgkDgutCTB1Yq
zT5DuwvAe+co2CIVIzMDamYuSFjPN0BCgojl7V+bTou7dMsqIu/TW/rPCX9/EUcp
KGKqPQ3P+N9r1hjEFY1plBg93t53OOo49GNI+V1zvXPLI6xIFVsh+mto2RtgEX/e
pmMKTNN6psW88qg7c1hTWtN6MbRuQ0vm+O+/2tKBF2h8THb94OvvHHoFDpbCELlq
HnIYhxy0YKXGyaW1NjfULxrrmxVW4wcn5E8GddmvNa6yYm8scJagEi13mhGu4Jqh
3QU3sf8iUSUr09xQDwHtOQUVIqx4maBZPBtSMf+qUDtjXSSq8lfWcd8bLr9mdsUn
JZJ0+tuPMKmBnSH860llKk+VpVQsgqbzDIvOLvD6W1Umq25boxCYJ+TuBoa4s+HH
CViAvgT9kf/rBq1d+ivj6skkHxuzcxbk1xv6ZGxrteJxVH7KlX7YRdZ6eARKwLe4
AFZEAwoKCQ==
-----END CERTIFICATE-----
"""

  # VirteeMilan VCEK  sha256 3bbfb6ee259f75a95d13168cfdf2e034181bb93c7c016825731cbe8ea16c95e1  (1360 bytes)
  VirteeMilanVcekDerHex* =
      "3082054c308202fba003020102020100304606092a864886f70d01010a3039a00f30" &
      "0d06096086480165030402020500a11c301a06092a864886f70d010108300d060960" &
      "86480165030402020500a203020130a303020101307b31143012060355040b0c0b45" &
      "6e67696e656572696e67310b30090603550406130255533114301206035504070c0b" &
      "53616e746120436c617261310b300906035504080c024341311f301d060355040a0c" &
      "16416476616e636564204d6963726f20446576696365733112301006035504030c09" &
      "5345562d4d696c616e301e170d3233303430333139323334335a170d333030343033" &
      "3139323334335a307a31143012060355040b0c0b456e67696e656572696e67310b30" &
      "090603550406130255533114301206035504070c0b53616e746120436c617261310b" &
      "300906035504080c024341311f301d060355040a0c16416476616e636564204d6963" &
      "726f20446576696365733111300f06035504030c085345562d5643454b3076301006" &
      "072a8648ce3d020106052b8104002203620004a17accd80b1edeb0d39f30aa5c08b1" &
      "4c7070051d293fce99a0de55e662a7c276857aa34067cd9ecf521c90489c0d4075d5" &
      "6e61ccda2be696efb1b9d4e9d15dd2fea32b0248409acc91481722402d31a2373ce1" &
      "b0465098070f4f63cc7620a3e9a382011630820112301006092b060104019c780101" &
      "0403020100301706092b060104019c780102040a16084d696c616e2d42303011060a" &
      "2b060104019c7801030104030201033011060a2b060104019c780103020403020100" &
      "3011060a2b060104019c7801030404030201003011060a2b060104019c7801030504" &
      "030201003011060a2b060104019c7801030604030201003011060a2b060104019c78" &
      "01030704030201003011060a2b060104019c7801030304030201083011060a2b0601" &
      "04019c780103080403020173304d06092b060104019c7801040440d49554ec717f4e" &
      "5b0fe6b143bcf0405bd7ae304727edf46603f2a76aef6a3abc15d7af38db75703902" &
      "9f0efacfd08e244324884738c72b082e2f87a44d541eb6304606092a864886f70d01" &
      "010a3039a00f300d06096086480165030402020500a11c301a06092a864886f70d01" &
      "0108300d06096086480165030402020500a203020130a30302010103820201004e8b" &
      "39ba08c0b93dd170369d91e74fdfde0d46012a3c5dab807504da09fcc21982041022" &
      "1ef949e8938274a51f696e98667792afb047a68754847f6f0cc2a92a9a19d76bd1c0" &
      "5336feb89ffdc630484edc45b9bc60d82ed8e73e5bec875e06961fe9c1c94b8e7044" &
      "a0cf4ce2467e96d23bb110ebe5e432d51a2e56ccac6ae824b1e57cb68523d70c8b9a" &
      "c390bd679a25f1839c498853e8ebc99564b880475ebc5ce1a14c0d6e572a54e6036c" &
      "4c7008a78b663a5323d3875190af1bdab603db46cdbfcd534462333d6746b7a939b9" &
      "55c633b55d9e43bd2f19506005ea17fc35d69fd3209e1ee16574bf22ee61125575f1" &
      "22b3010641ec3058f49a38f1474199eba4b4b688b255d52e42f5890cec7fb57d9558" &
      "795451dfd0fd064feb088442a2a91a154819673c951764a2bd3e80a8bb2f0eeaa0fd" &
      "4b2fc059f455eaa462106e6e50bab970fa66ca20975a9889bc5f9323be48030a8a5d" &
      "962e21c4817df8fef4b749a7afc021e0140b91f43c6918e25a7e359dd1be29d2bf8b" &
      "694fd05805ade89f87dccc249a5e355ec2fdd51ee23fc5794e55d1800f2cdf504961" &
      "44abdc6aabca4ef9faa8be2f6cdfa9fdbc1ade2fa931f9e1e9115cbdc7afb525528f" &
      "4d17788bb309295db3af2efaf08914209a831135d517a7795407a5d7614006015363" &
      "f98f976f2f4695efbf1788d572f06a9a1dc67abf60bd9cd43e4a437932fe7d76ab10"
  # VirteeMilan report  sha256 120d77b213c8868dd42f160ccb0114f05336ec715f6d51070f534b33c7e03f3b  (1184 bytes)
  VirteeMilanReportHex* =
      "02000000000000000000030000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000001000000030000000000087301000000" &
      "000000000000000000000000d447b55d197491bfe15cf298f9de9986b7a7c4be2468" &
      "b4f6e2d53b71d7c645810b0f2cdfca0040433be063fc1a8293f0f3f8dae7b79fecb3" &
      "d1cd82bd6a93ebfd7a1e5c266c0108dbc9bb94fa926951320940915d0aafb42464bd" &
      "88b579ea158d3e1a0dc39b2c60bd95b9c480cd81841f000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "000000000000000000000000000092b3b47d59f0a2a10a74c5678868a80238cf593c" &
      "01a82f3cffb878e904c28d5bffffffffffffffffffffffffffffffffffffffffffff" &
      "ffffffffffffffffffff030000000000087300000000000000000000000000000000" &
      "0000000000000000d49554ec717f4e5b0fe6b143bcf0405bd7ae304727edf46603f2" &
      "a76aef6a3abc15d7af38db757039029f0efacfd08e244324884738c72b082e2f87a4" &
      "4d541eb6030000000000087304340100043401000300000000000873000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "000000000000000000000000000000000000000000000000000061ab4f11aa661997" &
      "625f233df42a4ad54440eeb7a96ea63de170cbc29c37c005cb54054881ec7d2bee56" &
      "9b02d07f8272000000000000000000000000000000000000000000000000209d7eb9" &
      "be919a1d0baf1d57fe6ebfeabbc53b778c6e977e40b15ca931bb6d44c5ab9e30cfdc" &
      "7346cb41ac083b90bf49000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000"

  # GsgMilan VCEK  sha256 0d057f9b6e29a69eda9c0154b259567d291c1c08d73a11e9d31ace07c435b6d8  (1360 bytes)
  GsgMilanVcekDerHex* =
      "3082054c308202fba003020102020100304606092a864886f70d01010a3039a00f30" &
      "0d06096086480165030402020500a11c301a06092a864886f70d010108300d060960" &
      "86480165030402020500a203020130a303020101307b31143012060355040b0c0b45" &
      "6e67696e656572696e67310b30090603550406130255533114301206035504070c0b" &
      "53616e746120436c617261310b300906035504080c024341311f301d060355040a0c" &
      "16416476616e636564204d6963726f20446576696365733112301006035504030c09" &
      "5345562d4d696c616e301e170d3232303932343030353532385a170d323930393234" &
      "3030353532385a307a31143012060355040b0c0b456e67696e656572696e67310b30" &
      "090603550406130255533114301206035504070c0b53616e746120436c617261310b" &
      "300906035504080c024341311f301d060355040a0c16416476616e636564204d6963" &
      "726f20446576696365733111300f06035504030c085345562d5643454b3076301006" &
      "072a8648ce3d020106052b810400220362000448ec9f362eedee5ea1765939d30ac6" &
      "c056c8219ade71c585d2e21f773cde430f30b20d6ab817df8e8de1d85cf293a3854f" &
      "08609d7f00f4852ccd83882772abfe82ffcc70fa8a63fb94f532c840f2e7a835607c" &
      "c725bf125b884ffec9044e3ef9a382011630820112301006092b060104019c780101" &
      "0403020100301706092b060104019c780102040a16084d696c616e2d42303011060a" &
      "2b060104019c7801030104030201023011060a2b060104019c780103020403020100" &
      "3011060a2b060104019c7801030404030201003011060a2b060104019c7801030504" &
      "030201003011060a2b060104019c7801030604030201003011060a2b060104019c78" &
      "01030704030201003011060a2b060104019c7801030304030201053011060a2b0601" &
      "04019c780103080403020144304d06092b060104019c78010404403ac3fe21e13fb0" &
      "990eb28a802e3fb6a29483a6b0753590c951bdd3b8e53786184ca39e359669a2b76a" &
      "1936776b564ea464cdce40c05f63c9b610c5068b006b5d304606092a864886f70d01" &
      "010a3039a00f300d06096086480165030402020500a11c301a06092a864886f70d01" &
      "0108300d06096086480165030402020500a203020130a30302010103820201002738" &
      "4bc4eabc854df1ab98e59c54d8d2c0d3371ffeebd6e0c65fb994e6d011124b3a2c36" &
      "34948d1075aada3365a3fc6e6a17747a002b4ce8ef2ae7b03bfd9b0b65d655e64a50" &
      "214bcb155db3a3491105a90388b76337d2395c578e83e055663f4e71f89b31856b9a" &
      "e48fa70c1d47c8511fbb13c2b8956730e63e2f82e2da02d5130f405ad950d4bfbb37" &
      "d09f0f2d9cfb727f06cfb66969d1a64718d4917f680746b055543d9bf69adb3fae9b" &
      "475ec930d582cf53d7b951a72adc254d7de12447aad071880a0965a3ca734a522417" &
      "7d6fd916782716f5b4fd26470e5aaae0eecb4df59e6a0d037358ba7cbf8e2ec1b496" &
      "fc1f3c6aa710609fe143507c99aa352cc6a6abbd306021a2b510440720d0bd1c4a2a" &
      "ccdf0f33b1565e3034d67132c94a621e1ba9ede31a3b3e6717c2c3bf97557ceb98c1" &
      "74895dfbb2b487c338cead73f99eb0acb54a534812c572e4c42274ad2120d2062dba" &
      "5744f3333411025e46baffabf16f772d2c51698161e4fcc00ea37150beb03cd96f7a" &
      "b910fae9a906075447d975575655e8012feed383cbc7e9dc78d3d373073ddfe22518" &
      "a29d04d464ee13ecddb4c8d87fe865f6345b2a0c612087e7c8830c47771718c32757" &
      "70a95ba25997f6ae36effe2319376a161c552472710b4214c8cd25c8f3219dab104f" &
      "e381806e39dbe778da75992598078be2c463d450df26254a6116fad32bf886a50c5b"
  # GsgMilan report  sha256 377e6241d3b373ab1df80c0f96978594e7e21f4797dd6ea95e2957e1c1e26060  (1184 bytes)
  GsgMilanReportHex* =
      "020000000000000000000b0000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000001000000020000000000054401000000" &
      "00000000000000000000000001020304050000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "0000000000000000b07af9620f3b839b47996422ddec6058338951d984e312115131" &
      "ea82705eaf5b6bdf8a9ece31a5a608eb0cf2e4872b01000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000008edc638e1857c555d21f6b11bda3c8b1b5a09dba" &
      "4852b4c8ee7aa2f16f22cc0affffffffffffffffffffffffffffffffffffffffffff" &
      "ffffffffffffffffffff020000000000054400000000000000000000000000000000" &
      "00000000000000003ac3fe21e13fb0990eb28a802e3fb6a29483a6b0753590c951bd" &
      "d3b8e53786184ca39e359669a2b76a1936776b564ea464cdce40c05f63c9b610c506" &
      "8b006b5d020000000000054403310100033101000200000000000544000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000004f8e8b5ab8f8f969" &
      "ca4f27b6bba65faa5313ae72f66b893874bce5d62d3b08babb321ac2c990a5d24b50" &
      "a232999cc821000000000000000000000000000000000000000000000000e689246b" &
      "a09566b6b6f91c3004a15f8f34bd65020b7e16f447f876428bd7e90adb2c157fc931" &
      "1becf6119498555d10e0000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000"

  # VirteeTurin VCEK  sha256 a4a6abff1c435f214cfbc35e4dadae55e467454d53dc417251b3ff1a169fd7fb  (1289 bytes)
  VirteeTurinVcekDerHex* =
      "30820505308202b9a003020102020100304106092a864886f70d01010a3034a00f30" &
      "0d06096086480165030402020500a11c301a06092a864886f70d010108300d060960" &
      "86480165030402020500a203020130307b31143012060355040b0c0b456e67696e65" &
      "6572696e67310b30090603550406130255533114301206035504070c0b53616e7461" &
      "20436c617261310b300906035504080c024341311f301d060355040a0c1641647661" &
      "6e636564204d6963726f20446576696365733112301006035504030c095345562d54" &
      "7572696e301e170d3234313130363231313430305a170d3331313130363231313430" &
      "305a307a31143012060355040b0c0b456e67696e656572696e67310b300906035504" &
      "06130255533114301206035504070c0b53616e746120436c617261310b3009060355" &
      "04080c024341311f301d060355040a0c16416476616e636564204d6963726f204465" &
      "76696365733111300f06035504030c085345562d5643454b3076301006072a8648ce" &
      "3d020106052b810400220362000451f1e1b9412b682676305c41a32a4189fe3e0a5b" &
      "549a25562a061aa0a8bdec40b5102af7e08666936045253b7c05087b45da0d2c4b69" &
      "d05ddcb6a35c9892fb6c6e0eeddf98b7e08df71963536b808cabad88a88b4d2f4832" &
      "0442de63666191cba381da3081d7301006092b060104019c78010104030201013014" &
      "06092b060104019c78010204071605547572696e3011060a2b060104019c78010309" &
      "04030201003011060a2b060104019c7801030104030201003011060a2b060104019c" &
      "7801030204030201003011060a2b060104019c7801030304030201003011060a2b06" &
      "0104019c7801030504030201003011060a2b060104019c7801030604030201003011" &
      "060a2b060104019c7801030704030201003011060a2b060104019c78010308040302" &
      "0109301506092b060104019c78010404081e550a8ee5cf9f4d304106092a864886f7" &
      "0d01010a3034a00f300d06096086480165030402020500a11c301a06092a864886f7" &
      "0d010108300d06096086480165030402020500a20302013003820201006a3d3d8319" &
      "b058bcb47de1767d26f4a17d4fdd01d707f9a4e7caf5725c4543aa024c9381b8bc77" &
      "46cdd7623d0760477cbcd105464102ee4173a3def4dafba0fef9fd611654fbed38fa" &
      "8bc84fa59b1cceb1800b3363b133c61a4b03fbc118efcf454068b575dd6572037cf3" &
      "224a63dbb15f6785b976af1bb95476c4cf070a8d37c270e8897ee6bd29b9b1a6fbee" &
      "979e63b3d81d6c34c7ddbe6f4bedf9790bdd0d604d93f1677fde210204539851dd2a" &
      "d38b1e60cf4f4c3fa0574e5b56e34555f7646049f3a253f8973b213a71a1e04274e8" &
      "daae4a9566b2ecf694d84f4a0c6843bc1093a011b07f971970dca0896c41ac90582f" &
      "951d3fa84f6001a3d76190dcd143c91b4b172243c5093362266e8df64606e1aa279d" &
      "a5d2e57d8fff94f58e0163a8fe25981179b60ce7fad9df5b0c64b193c7ad67a235e5" &
      "80b237bc2809eca0f0489453d4c08d5060d194af9840d13cf4970f0a2b0e1b909edc" &
      "16e52fce4f7c9a71842fd1988f8914c8f7ace9c01fb1ddfb423a7c9f9b1dbe50ce9f" &
      "02238916f3a904de53b36bc5aafd775afcb8cb05f7657437d51800d7c9452ffd4a59" &
      "a3174babbb6cae1615ccbe32e5ee016bf89faa6495e4951d7e342ca2d535eaad0eb2" &
      "f4d2ec58996ebdeb24e6d0dfc28b13fea7ee9dda5ab829cfb936f17f0ee07c002cf4" &
      "1754c03c1076400e823a9d7dbc0c343ce94abd642589f0cabaca7f0a93d49f"

  # impostor Ark  sha256 5f4bec10a70cdeb137b599db0e459af24ad4adb5b2e1a6bc1134ad5b8ddff542  (1639 bytes)
  ImpostorArkHex* =
      "3082066330820412a0030201020203010000304606092a864886f70d01010a3039a0" &
      "0f300d06096086480165030402020500a11c301a06092a864886f70d010108300d06" &
      "096086480165030402020500a203020130a303020101307b31143012060355040b0c" &
      "0b456e67696e656572696e67310b3009060355040613025553311430120603550407" &
      "0c0b53616e746120436c617261310b300906035504080c024341311f301d06035504" &
      "0a0c16416476616e636564204d6963726f2044657669636573311230100603550403" &
      "0c0941524b2d4d696c616e301e170d3230313032323137323330355a170d34353130" &
      "32323137323330355a307b31143012060355040b0c0b456e67696e656572696e6731" &
      "0b30090603550406130255533114301206035504070c0b53616e746120436c617261" &
      "310b300906035504080c024341311f301d060355040a0c16416476616e636564204d" &
      "6963726f20446576696365733112301006035504030c0941524b2d4d696c616e3082" &
      "0222300d06092a864886f70d01010105000382020f003082020a028202010088ed56" &
      "39199c5d88cc34366f35ac7ce36efdb04e999c3097b7fe54d3a0b11a533b1f118f59" &
      "72e93ded297ef7f891bf29aa94e8116798284835dc2adf160331628770afce18407e" &
      "05eebb963fe8ec736894387a1ff8e2ef4ac57333be0c7853045252287fab887f454d" &
      "793fd94f1ff3f2533c68ac73ab4c69dce2d80c76abf7c316d679e22f7b77e0a34a9d" &
      "90a02d12aa8cfb9247d3813d769261d2c9f5eeb2ea0fb500af1de6da5604c506750f" &
      "52ce11b00ba61ad68867ab9846476845b62e95d75b94742ee699f8665ba924e09bc8" &
      "1a99ad20865f868aaf84a44af52a2a892f3d462893bd4a773f00ac19bc8fffb3025c" &
      "74e4cff2a06d195c0e7feb92d176d8ae3c98a311460ed7f32404bac1231b454528ba" &
      "078307a79f02615f3df82936f3e0930502177bf103bd05281439a3c58d5ba0fe44fb" &
      "e8992b43773db92ab8b83c6236a7254f1ed379b42881f69ec6b9a878a9e2acd70020" &
      "71c1926f49df50330ed9e2e5901f8620d10c8fb189410a74699928acf47f43be7363" &
      "3564afe0ea4f4ba56d821102a03e21deb17292281ffc81ac4acc3a49981b6605e986" &
      "f3bbff18f796bb3d07364d5fef8c85666bd37adca8597d31e2504ff274933fed2e78" &
      "fb044a41ef4c7a6c9f2abc52b0ddb440ca1de71747d32ffd2825f5fd3cd03f113317" &
      "6ce687f05d787aa1de9be5420fcd5fa2ec70dc32089c9b1d7bd7c987baeba4838d02" &
      "03010001a37e307c300e0603551d0f0101ff040403020106301d0603551d0e041604" &
      "1485ac1ad143f7c8ac55d4c51d4148abd5784ad453300f0603551d130101ff040530" &
      "030101ff303a0603551d1f04333031302fa02da02b862968747470733a2f2f6b6473" &
      "696e74662e616d642e636f6d2f7663656b2f76312f4d696c616e2f63726c30460609" &
      "2a864886f70d01010a3039a00f300d06096086480165030402020500a11c301a0609" &
      "2a864886f70d010108300d06096086480165030402020500a203020130a303020101" &
      "0382020100689892c3528e182904eeb19a3e163cd0d07a27265e025c6e1adc1d2ed3" &
      "48c29a2748481ee6d12fad1f311656fa7e1fe8ee10565c632f88862be39a71f9698b" &
      "0916923cbee92d708466881e5c12117772d5a04470f10982d14f0be082ab3268bd98" &
      "7589d74020e964a70907221456e09359edbb398bc4f7dc2d1eab25e17b3570144194" &
      "449819458d4da24d1e05cb5dab23ca86f3d288c8dff6a2927c9e027b413c33dedbd9" &
      "a7d7c2a77d9930aad69da4d97cca117ebf97e319a571640d3503541420ebe968d259" &
      "fb8f066d8fc9f7c79d3eaa60737d4c0adc2a8baffaa9ce59f1db42a69657b0e0a4c5" &
      "eb4feb556735f83d1d4b2ad43ebf48c916c147ba2f7a4cf7a9a6b3b6d8cd156511a6" &
      "b73900901cd57b6b897d1ed7028bce565c842cef1c766927f49ef470873d3dc540b9" &
      "856a5f51ded131fe4ac6abfe73c6978808d0e21f44f90af01e6cdc1f02d8cbddbd88" &
      "4f9d75cfa6ce3e12021cb76c0378bfd243e3657f3b83a50d89b1fabcf3049572e93d" &
      "342b4e8e3a6cb34e4b74969ea50930149b0730a27a0dac999727507a12c0638504c3" &
      "79e1e1199a031b615ab5f424d2c67c51c2881276fbc69a2c47ab286a5f034ce2b13c" &
      "372d993251e50b76f0a6bc294f66e55cb7f9cf63b294011b0e5ff5fb84f45b49f867" &
      "7dfe94aecebf4a87a9a4f642decb718a7b6aa2d3f31ef3b749d2ee33e6dba39c4e1d" &
      "5406080b7c5619"
  # impostor Ask  sha256 86c38916ed31d869f7d109adc35a728e1fc22de671be531ffa2866ef62bda9bb  (1677 bytes)
  ImpostorAskHex* =
      "3082068930820438a0030201020203010001304606092a864886f70d01010a3039a0" &
      "0f300d06096086480165030402020500a11c301a06092a864886f70d010108300d06" &
      "096086480165030402020500a203020130a303020101307b31143012060355040b0c" &
      "0b456e67696e656572696e67310b3009060355040613025553311430120603550407" &
      "0c0b53616e746120436c617261310b300906035504080c024341311f301d06035504" &
      "0a0c16416476616e636564204d6963726f2044657669636573311230100603550403" &
      "0c0941524b2d4d696c616e301e170d3230313032323138323432305a170d34353130" &
      "32323138323432305a307b31143012060355040b0c0b456e67696e656572696e6731" &
      "0b30090603550406130255533114301206035504070c0b53616e746120436c617261" &
      "310b300906035504080c024341311f301d060355040a0c16416476616e636564204d" &
      "6963726f20446576696365733112301006035504030c095345562d4d696c616e3082" &
      "0222300d06092a864886f70d01010105000382020f003082020a0282020100acdbf2" &
      "bd4d56ff45276641fb2c1b5e0f0884a1b4ff1c58d7028b7e6dbda1c4b24c1815739e" &
      "34a51bb893c2d1b7f3c01092770a47331c98003c425af6794717a39867c4c6a2e509" &
      "a534ea5b395b4f7b4a5d42f27cafae278350a10253088c3d25a625a0eba4db049c8e" &
      "200682c194a8f742367360fae19306e108cb5d0fd3e6a4dea13b4da878341f7ce023" &
      "427ab4432c645695a7ccea6f586a18fad58f20e913beeed5c022b7eaf07ab91ac28a" &
      "1781a71771a6e99ca0336fe99f2b6edda297a0cda3a18369d65ae14bb19b2102dde0" &
      "53ef0db539c9537590eb328e7a096e65dcc41cf9ac024000fbb1d11967ac183fe949" &
      "8b20fd7f7ca7a569cf3ffe8ebc82b26666844cb1a745c8e24b604f85b17ce07526e3" &
      "412962192e7ebeb077de464c540f4a751c09ece452a05088e240beb7333a09d09cc5" &
      "d4c5098a02f842776eadb1829db4a01d7785dc03e0defbd251cd9e35420ec16cd15a" &
      "77545bb6a598265a62099b04cf495bbb3f48ab45916886a062e75ad9aae2fa928464" &
      "10adb87032b02b2413dcff29c038791e85b0edb727d2a070be1552253d5f16cf6698" &
      "b082a437621eaf0a80b7c232745e8805b5215f827c7739733b5bd4774a3754e91eb2" &
      "6f9611aa51d7ad5957ebc92f6471e57e46531cbfbfd8b8f720277c3c74b7efa70a02" &
      "105e4326a0e7c460d7c0bfa67d4872735a4e74c1407ab3165d7cc73f754915305d02" &
      "03010001a381a33081a0301d0603551d0e041604143bc66e182ac3fd3d6264489be3" &
      "b7472cb4fcbff8301f0603551d2304183016801485ac1ad143f7c8ac55d4c51d4148" &
      "abd5784ad45330120603551d130101ff040830060101ff020100300e0603551d0f01" &
      "01ff040403020104303a0603551d1f04333031302fa02da02b862968747470733a2f" &
      "2f6b6473696e74662e616d642e636f6d2f7663656b2f76312f4d696c616e2f63726c" &
      "304606092a864886f70d01010a3039a00f300d06096086480165030402020500a11c" &
      "301a06092a864886f70d010108300d06096086480165030402020500a203020130a3" &
      "0302010103820201008101b3572d3b9a93e8509df34a31a5dc7d9562ce86d110e6fd" &
      "2e91ee1eaa2ab3b0eb2c2c63c94c91691d4bfb1056641001651a019517d09cc6e7da" &
      "701bb6745e345544d72a0065d97dfc9239471169d37e911240551212fbb12b2e3eb0" &
      "f5e1a218968e28d38d4e6d1c6e8f9647099bf6174b8aa3438349c3282a9b099deeb1" &
      "ae45ae2b15cf474d37a357096cb4ad1d8a96aa23dc78732a5f3e9821b6a11ccdf786" &
      "279697080fbd50dc4ececdc56d8774e2ae6efa2484e93da912b353f82b84f05ae26d" &
      "011fb462ab6ad47b56734ca6a4bf0ef65bfc92534e6979760a7b50ed2f5cebc48acb" &
      "64a55dec0ba424bf1c75d28d226f2f72fbf7f014a203d407862255c2c172d546e8ae" &
      "44590b478cc97a95d3de028df31a27ec05fad4a68ccae346c793cf57269bad468720" &
      "a116f9928dc0048e20164ad214c60ee09cd44a93f143d21d6516c8fee70915b481f0" &
      "b3a6a940faca3477c7c046f87b1db8c46e94a16c16324e024161c91dd4b1b5d2c2c2" &
      "0b283315400ce941b3bd945da9f0858b958e10f5e2006329002be81befc986f8f8c6" &
      "5f67e56fe7fed0fea343751b87e8e8f81e2fee76a9a6d9f0d18642b7673f93c9023c" &
      "12b78a7fb8c5bff5d8a26080eab0342daa4f6445c286df98aa287becdee00347ff92" &
      "386659bf41a2a05438f945cab8b37e3238f382cc17c150a0c031eba0fd371ad04cec" &
      "a29f5212b4517ccf1bfdba"
  # impostor Vcek  sha256 0d48aa172f2a211ed89763810dabac37bda51c3617186ac7c30f6366affa2df7  (1360 bytes)
  ImpostorVcekHex* =
      "3082054c308202fba003020102020100304606092a864886f70d01010a3039a00f30" &
      "0d06096086480165030402020500a11c301a06092a864886f70d010108300d060960" &
      "86480165030402020500a203020130a303020101307b31143012060355040b0c0b45" &
      "6e67696e656572696e67310b30090603550406130255533114301206035504070c0b" &
      "53616e746120436c617261310b300906035504080c024341311f301d060355040a0c" &
      "16416476616e636564204d6963726f20446576696365733112301006035504030c09" &
      "5345562d4d696c616e301e170d3233303430333139323334335a170d333030343033" &
      "3139323334335a307a31143012060355040b0c0b456e67696e656572696e67310b30" &
      "090603550406130255533114301206035504070c0b53616e746120436c617261310b" &
      "300906035504080c024341311f301d060355040a0c16416476616e636564204d6963" &
      "726f20446576696365733111300f06035504030c085345562d5643454b3076301006" &
      "072a8648ce3d020106052b8104002203620004b4b5c9689e42ef0ff4db434fc3bd50" &
      "80c1c6bdb4a18766c6bbb15ae45b4ceef32a751cb942a3a74ddb9cc4b1d734a2aef9" &
      "60e7f2533484a3515835a45d291d26283a94a9ef46de8016b5c146d1d20b42cfb558" &
      "643d7806c78d5192e263ac4787a382011630820112301006092b060104019c780101" &
      "0403020100301706092b060104019c780102040a16084d696c616e2d42303011060a" &
      "2b060104019c7801030104030201033011060a2b060104019c780103020403020100" &
      "3011060a2b060104019c7801030404030201003011060a2b060104019c7801030504" &
      "030201003011060a2b060104019c7801030604030201003011060a2b060104019c78" &
      "01030704030201003011060a2b060104019c7801030304030201083011060a2b0601" &
      "04019c780103080403020173304d06092b060104019c7801040440d49554ec717f4e" &
      "5b0fe6b143bcf0405bd7ae304727edf46603f2a76aef6a3abc15d7af38db75703902" &
      "9f0efacfd08e244324884738c72b082e2f87a44d541eb6304606092a864886f70d01" &
      "010a3039a00f300d06096086480165030402020500a11c301a06092a864886f70d01" &
      "0108300d06096086480165030402020500a203020130a303020101038202010089a9" &
      "45ea205bc9f2a0f0f717a03c30d3de5069059477f5785aa66365c3b4e4ca269e3b31" &
      "667162d960fde7a98199faf19b0cf4fcc46cdf7dc1bc9fc955182d9c189d6677c981" &
      "71c2f27208adb3de7662d21220ee9948b055f5f618af6d9688a51e0022a97fb7ba80" &
      "654ad5ba5704f1ac7c81feab0d91a142adb018def21c4c19acad7722ae69a4370a26" &
      "a726eaaf0e39adfc0755601caa9bc592ab33a627a96f8a23bb437f1e026f7dd2e314" &
      "758e47b3c5301c7c393dd4109b6b55d03ba0ced36665524beb45dc39402911ebd8a3" &
      "11c4fb23a6a894a2a63f1e723b22e986153483f3a5a72245b445c1dd49b0304e764f" &
      "d6f873559ef20e109cdce697b257881f7ec900650526f8070989c6ca14857de0387a" &
      "bd2e1bdbceb2bd4fa34f4c72150a97cb3e87dae32bb631c5e28828c8128f8fb31289" &
      "29bb377607e643cf8b07bbca7fb241a5276505021323d5baad304501cdb3084a8e1c" &
      "5d276da3382ce22ad6ef1f91a7a51b0e83ac7ac1ab81deb989045906c8e752821230" &
      "92af1cbca3e456464781807fe9ccffd52ca6aa3cacb1afdc30b97468f90b65c60350" &
      "861064f4aeb88dcecfa78c2fa02add33cceedec3c385278614fc2d2fe215d5af2b1b" &
      "ff14d85b65da928c11866cdad9e7ec459ff1006913365eca78842b59d1bf6ed6bf61" &
      "bc9e10ca39034888103ac2aec20445133825e10bc8f97a50d07455fa3406c72544cc"
  # impostor Report  sha256 b820c130dd814e06020bed6f99c6f2ead14cf144492a5727e64643f9fe031e56  (1184 bytes)
  ImpostorReportHex* =
      "02000000000000000000030000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000001000000030000000000087301000000" &
      "000000000000000000000000d447b55d197491bfe15cf298f9de9986b7a7c4be2468" &
      "b4f6e2d53b71d7c645810b0f2cdfca0040433be063fc1a8293f0f3f8dae7b79fecb3" &
      "d1cd82bd6a93ebfd7a1e5c266c0108dbc9bb94fa926951320940915d0aafb42464bd" &
      "88b579ea158d3e1a0dc39b2c60bd95b9c480cd81841f000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "000000000000000000000000000092b3b47d59f0a2a10a74c5678868a80238cf593c" &
      "01a82f3cffb878e904c28d5bffffffffffffffffffffffffffffffffffffffffffff" &
      "ffffffffffffffffffff030000000000087300000000000000000000000000000000" &
      "0000000000000000d49554ec717f4e5b0fe6b143bcf0405bd7ae304727edf46603f2" &
      "a76aef6a3abc15d7af38db757039029f0efacfd08e244324884738c72b082e2f87a4" &
      "4d541eb6030000000000087304340100043401000300000000000873000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "0000000000000000000000000000000000000000000000000000ee790f16226168dd" &
      "ed865a3379f91703473f5b014e3a27636ece6d406e2a403e016af9339d26ade91749" &
      "50e5156a089f00000000000000000000000000000000000000000000000042008479" &
      "5067b2dc5e806007714c3e541be47ec2e9a90fe86b6748a4c7ac0d70cd072c0c5737" &
      "6ca03e25486d804df3ea000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000000000000000"
