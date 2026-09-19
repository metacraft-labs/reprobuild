## THE FRAMING IS THE FINGERPRINT.
##
## `repro_hash/policy` builds one byte string -- magic, tag length, tag,
## payload length, payload -- and hands it to BLAKE3 or XXH3. Every action
## cache key, every CAS address and every local-invalidation hash in every
## existing cache, on disk and in every binary cache, is a function of those
## bytes. Reordering them, widening a length field or dropping the trailing
## NUL of the magic does not fail loudly: it silently misses every entry ever
## written, and a careless change could alias two frames onto one digest.
##
## So this file does not assert that the implementation agrees with itself.
## The hex below was CAPTURED FROM THE PREVIOUS IMPLEMENTATION -- the one
## that appended the frame one byte at a time into a `seq[byte]` and passed
## the finished buffer to the one-shot `blake3.digest` -- by running the same
## corpus against it before it was replaced by the streaming `framedDigest`.
## It is an external witness, not this code's own output.
##
## NO MOCKS. Everything here is the shipped `casDigest` /
## `blake3DomainDigest` / `localHash` / `casFileDigest`, over real byte
## arrays and (for the file arm) a real file on the real filesystem.
##
## COVERAGE. Payload sizes bracket every buffer boundary the frame and the
## hashes care about -- 0 (empty payload), 1, the BLAKE3 64-byte block and
## 1 KiB chunk edges, the 64 KiB mark, and +-1 around each -- crossed with
## EVERY `HashDomain`. The domain enumeration is exhaustive by construction:
## `test "every HashDomain is covered"` fails if a value is added to the enum
## without gaining rows here, so a new domain cannot silently skip coverage.

import std/[algorithm, os, sequtils, strutils, unittest]

import repro_hash
import repro_hash/blake3_policy
import blake3

proc corpusPayload(n: int; seed: int): seq[byte] =
  ## The exact generator the baseline capture used. Do not change it without
  ## recapturing every expectation below from the shipped implementation.
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte((i * 31 + seed * 7 + 13) and 0xff)

proc parseDomain(name: string): HashDomain =
  for d in HashDomain:
    if $d == name: return d
  raise newException(ValueError, "unknown HashDomain in corpus: " & name)

const Baseline = """
casDigest|hdCasContent|0|0915dba28f88ef86e66c924f11ab3df9fdf78980e0a9abd07f4d3779ce0266ac
casDigest|hdCasContent|1|18a818a6743b24c2b2b14474c30cd11e2ccba6193e36872ad2581f18eae435e2
casDigest|hdCasContent|2|0ee0a3347370522aeb15f985e067b06c7efb1aaba69a7e539db4e69f6a27342b
casDigest|hdCasContent|7|f89babbf1bcfc46b8aceecabb9a8e1d9c3ba01f9ad70f6f25559a23d2163289d
casDigest|hdCasContent|8|bb36a2b682bc858d1012d41654a8d17b616dc7f6a5c39e1c42ce799a67fa50df
casDigest|hdCasContent|9|6af12c565ac989846bf475f3fb12ea6384f12916e6a5e4c59b74b091e1e7e792
casDigest|hdCasContent|15|30ca3e21b9ba255fb994316ae6635bf3c2fadb24438cbf8b679756ebb6e04086
casDigest|hdCasContent|16|74e16f29ce59a88f166355cd28aa14ffbecb05cf3b9bacd8b81b940158e02552
casDigest|hdCasContent|17|d3dfb38be6af1c4837525ab2cf552c5bccc8b4df6ebc2cdacddde4eb492cfd51
casDigest|hdCasContent|31|5013a5b47a14cdbb898d780a59362f41b2c40ff99a2018c90e8c9124faca958d
casDigest|hdCasContent|32|357f5ea94b1389f0313386ed784462fc95fbc8b2a3a24624b0c90d88fee370e2
casDigest|hdCasContent|33|a9ece05e319084a565e381f49791984e8c86f86914ac46c57f90cce1fa1d4ac3
casDigest|hdCasContent|63|f6458d2e500c41d17a15be4dfcf00e0ef93e5ff24d069ad39b6bd0623bbf69f6
casDigest|hdCasContent|64|93d6a810306e867407f3e8a3a16392dc06090a9bfddf516773313d4ea2821ef4
casDigest|hdCasContent|65|77dc42d0043c61db4ee9b1cf3a0ab4f608527f853577c13a44eebf44c9e5090b
casDigest|hdCasContent|127|e9b1f76a86ed985aef571d7024c7fb9d96bc72a44409e07e7e7d7d2a2f92ceae
casDigest|hdCasContent|128|259fbabba19f3c9345ba3c0ca4e8caa66e197d76795f64fd394a5226eb183853
casDigest|hdCasContent|129|8ed412b602a5c72734ae128bd48e376e61d8d9df77ae02fde45e5ef11ae6984a
casDigest|hdCasContent|255|a5e28e52a3521d71c4bb970396b18b219f53a7ed0703d7f59e22c8618287b3a1
casDigest|hdCasContent|256|de9c028b6813541a708625731a446fc4dbe0b616a269db6b19aba5c9e8640b46
casDigest|hdCasContent|257|fd9ba4e75ef80d13f35430bdb2494db03bd2da6d73ffc976bb4025cb715579fe
casDigest|hdCasContent|511|f9a32650fc11b745196c026ae6dcfc0c5c19f82c76a5cf0da4a5b7f140cf39be
casDigest|hdCasContent|512|18c09fa449a9e01c4aba6a46fcea7be61377584321a9571d9c36fe9887c1cc6b
casDigest|hdCasContent|513|3d13afc91de2e9b400d63c704bd4da6a17be4e27446df0978dac4b4b669805b5
casDigest|hdCasContent|1023|5f1f3539601e93806d7becd36b988a1eaf93e623ad98e5dbdccc3ae082932a8f
casDigest|hdCasContent|1024|e9c6257f3b1b2b1e034db8b8e4b308fa003440b591f3652360cec1e22582f3d8
casDigest|hdCasContent|1025|207e68efae01c7914483462c054c2444a09c3e8f0ccacdc75dee02249cb979f4
casDigest|hdCasContent|2047|b4c8feb629626c1eaa8018943b0b5c38d6d5865f5977babf9e98285a3ef88849
casDigest|hdCasContent|2048|625d31e782ee78a4910cd10e3f7ba4b6e6cadd3515071be033cb9498b273cd91
casDigest|hdCasContent|2049|8b0fd2a46b8ac9f90e7504358e5cb3e95770657cd628305cf7f3c4176f2624eb
casDigest|hdCasContent|4095|4fc1d03c05e37de3865644eb5243d2fd3831f19e0344597626fa8409f0b3b1d7
casDigest|hdCasContent|4096|3014fe4996bd2dbad1eca946ab02e130f58ded30f29cc3c0c108fe2dd9472ec7
casDigest|hdCasContent|4097|f7050234b55ed7d5a1cc017a0b29a34a8950ef772eb535b372b3392b5198acb4
casDigest|hdCasContent|8191|6fc557b51ff30e718760d84950c89656676539b09d8fee9893694f46261b2e45
casDigest|hdCasContent|8192|bc9306c4b45d10e8f2b46bd0dff648f82b2b4a66ccbbf7c27bb302517f5ed4af
casDigest|hdCasContent|8193|630a6e9274cee5a68598909a56d5dc19998576221b4b303be8918fc7a1527311
casDigest|hdCasContent|65535|cbd2399b21e58661b4c8fad7dea507d7e123a34d2c66dd4cee309b89bfe28e2d
casDigest|hdCasContent|65536|de70e16f4569a1e15d9b53344f9f6e17af6586d95101db016b8e326289bc4625
casDigest|hdCasContent|65537|ea07287c7691ec133c540dc1854008b4823665822b13e465615809c808b24aaf
casDigest|hdActionFingerprint|0|78f91bcc7d5f243f9c4797c65d427102d2e17f14d07bdce546ba1372322768b5
casDigest|hdActionFingerprint|1|451de996a32e09ac466ee06741081bc58b4b8c8adfd73231ee957479089fec99
casDigest|hdActionFingerprint|2|7e48968cfc0691ead42112889bc78247b3b328888f662ecbe01170d7256cb3e4
casDigest|hdActionFingerprint|7|67ad29b7327da7a26d73601082dbe11791e47f00e861ee6600a07a29a2a6c2ff
casDigest|hdActionFingerprint|8|32dddca0914df169c007526d14391759cf8cc75d8df1d0d2d28839f6dc4be52b
casDigest|hdActionFingerprint|9|341dc63377fb371702291e384d93cc573d69ef8efd618200e9e079f3305ea552
casDigest|hdActionFingerprint|15|07dd8f34a43993b7ceaa1e688d4c082290065ee284a604967423e3221abcadeb
casDigest|hdActionFingerprint|16|23148e55d09ba98087b38d2c0f8318c675869c19743224b8d88b9f8e84a44f14
casDigest|hdActionFingerprint|17|e2a972446e7df3b8ea9348ceff3a20e82f08ffaab25cec591f280784b296c7b1
casDigest|hdActionFingerprint|31|1493b66f0e0b006f45e41c4e9c482b2ae834e4ec1b083ef1e5916e43b849c3a7
casDigest|hdActionFingerprint|32|a365f7dde8b6a52061fce27e6acbb07b8de156188e359df86333166ea2f597ff
casDigest|hdActionFingerprint|33|10ec353dffceb511523ac60c9e809c243955d7190680f49124602a2f6858b243
casDigest|hdActionFingerprint|63|f80301a957879a511543d7f7d2fbb7f0d77ad2a244eb1169e8580118f1af4e22
casDigest|hdActionFingerprint|64|d7a1b2ca184411462e4d11be7e8c91c3adcbf5d890f91927ffddecee5c7baf51
casDigest|hdActionFingerprint|65|cb57b9546cd6bf02a76a1e30d7120ff9fb01428fa771f4d87359a078743ca278
casDigest|hdActionFingerprint|127|ac4a7c9c85159746f9fa8d9daacc755993d97e75b7d9bb40f07680fa02d248a4
casDigest|hdActionFingerprint|128|0a301dfa97388f5012fe977e682277401b21714a1a4705a6d833fc70c28b30e2
casDigest|hdActionFingerprint|129|8892028a27a54345a34255944c3a7d354ec5ef7cc88e276db6df0fce6784933f
casDigest|hdActionFingerprint|255|60d299eed834e75d4c8788d5a4ae831386ccb6b301204e5853b6ba080b06c50d
casDigest|hdActionFingerprint|256|2cd8d4f6beab53d457de865b7cd6d6ef7ba985236b17f225bf152eae809ee5e6
casDigest|hdActionFingerprint|257|b63ab2500c07a02c50edaa8ff20b67a9f32797e129b05824759248f96e375c7c
casDigest|hdActionFingerprint|511|0c59cd9b373285ff52876169e33c58f2e5eff52793f6628a1770cb3d3ce02a6d
casDigest|hdActionFingerprint|512|72b1146e81b2254a19b6b5f02085bddf85a20502a61fff0c2e6b28a59a14bfd4
casDigest|hdActionFingerprint|513|b46a8458b70fe4b8924db0f8288f267b44ea35ac1dd31ef9168bf06dec753407
casDigest|hdActionFingerprint|1023|55d05dd774c1414d9c5f6d68b9515fdd61427d35b40d433cc4563dfda9da2adc
casDigest|hdActionFingerprint|1024|90c90f0c8e748c7dc678754ee3cc0b746225d84d8b6796d2d1ed309a0b535e70
casDigest|hdActionFingerprint|1025|63838560384e5410e6c8bf20a49c793c4b7cfb19a32b06fab04216635a26acdb
casDigest|hdActionFingerprint|2047|540e5c47923036cc0fdc0adb8c0705575d04b132e5e543abb906bd3d2fe3997b
casDigest|hdActionFingerprint|2048|cfd3f220527d1a910d5a2948987a6ec39695e80775d2a9f0e0f818bfee24d32f
casDigest|hdActionFingerprint|2049|a61c00b6dba1f819e8d7355c3113bdd9fb84f419f2565cc8b1fe574f3b555a74
casDigest|hdActionFingerprint|4095|042f7d58a0b41b29ad81b1e6d0e6911b32cbdefd14f73940a30620235e5a4d4e
casDigest|hdActionFingerprint|4096|003ee1cb104e993cfba135ad9d9c2f10a0f626e166c1846d82191d7e7c80b3ac
casDigest|hdActionFingerprint|4097|64abf8d3e9c03694f35febf34b6c2fee92936671f01f11ebabf4cfd94c1f0368
casDigest|hdActionFingerprint|8191|993466745d3512c860a178a3212377a3c226f4dd12d1abe78dfb73bc2a364fef
casDigest|hdActionFingerprint|8192|a72fa3a93fba39fb7a6e403702d0c2af0c709042820818c2d9003cf034718f50
casDigest|hdActionFingerprint|8193|b82bac8fd7428e8293501d3705f1c8a61b54aadab8d7255877e167fccd6ea87e
casDigest|hdActionFingerprint|65535|a8a908ac6df662c72a097ea7f1378c0156957fa551da19dd82598a111b63f949
casDigest|hdActionFingerprint|65536|5c7366c78e3c8eb1ed35c52b3f74e859df57ef1e9b05acbfae2a842b72995758
casDigest|hdActionFingerprint|65537|78dea69d87a60a523506ec2d9d46eae578606093ce0d5dfe4c86f37acc441ca9
casDigest|hdMetadataEnvelope|0|9aa69fb0025f8eb6f8492b26a2dbb086fdc3ee22725b2889175c0835a95fd8d3
casDigest|hdMetadataEnvelope|1|93e465903187f34d7a12716ec83bb735ab4683a86facdf7c459f0378303bd5c1
casDigest|hdMetadataEnvelope|2|795c09d5e361b270d6e0a9f567c351f32c4d2c32848e7b23274956eff534e07b
casDigest|hdMetadataEnvelope|7|0d16e3ba0b3bcbc55ac24c381b77ee05afbc7683a5c2c9709ab3f392a520f62e
casDigest|hdMetadataEnvelope|8|88189dbfb9d5a88d0d5a80099330eee890e61e15dc69c0d5ef9ee8efc5b0f967
casDigest|hdMetadataEnvelope|9|7fe7672de18ab2ba418d9d2ab7d5ba12bb799a60dcec88ad47cf3ba9f68800e4
casDigest|hdMetadataEnvelope|15|5a43cd15505166a7a37e990b9099c73d31741a782580b89be4d9719c6644529d
casDigest|hdMetadataEnvelope|16|290fc0bafa3442069ac61147c08f85a113dd618f4098bb341f7b4802f0ae4416
casDigest|hdMetadataEnvelope|17|55b7f4d9dd2ecc1bb63d433f28839847964bdebe638dcc4f55cdc7afa54603cf
casDigest|hdMetadataEnvelope|31|8d2aa1449f83bac475d06fe15f6d53191ef4fde98aed595c08542c4abeedfb6b
casDigest|hdMetadataEnvelope|32|d01f0931752e8fc6ed5f8781b59c7e160fb54e99f45a4ebcf5aa2d4881a7f5f5
casDigest|hdMetadataEnvelope|33|57cfa4a821af0fbae79ebad573e663a5bfdf6b052f6979ab4bb811bd533e68ce
casDigest|hdMetadataEnvelope|63|9ced4c23ae0cceabe11a69c5b4f0c1c35365e539f98ad3f20058b1fa31959ac2
casDigest|hdMetadataEnvelope|64|a7dfc5cb67ce0504dea92bdd8e7a12624479afa77501d096d0d0009926f1b4ec
casDigest|hdMetadataEnvelope|65|c57786b4b6ab3f1afb1d0f08428037bc904719d26ccace8931598987b78ae1ee
casDigest|hdMetadataEnvelope|127|c5b11914c0268fb216b31633d22b4c06fd429c8c3a564eabeea60288589cc7bb
casDigest|hdMetadataEnvelope|128|1d87cb15ee445c6d37cfd6841dbd70a0aeb1b8af96ed1175afb0d8ccf0384ed9
casDigest|hdMetadataEnvelope|129|ea7bc4f0a9aba514af9a85aa7a982670299481c2f03fc6b60c3e8445a1c34a10
casDigest|hdMetadataEnvelope|255|d711caea12d1be5bcc3af450486d181ae2a98bac85b1e305c4ae39149ea0f1ac
casDigest|hdMetadataEnvelope|256|f08d7170234b1c8ef86ae8a02782d9d18d52ed9a9e5faaa714e96892ef9c2623
casDigest|hdMetadataEnvelope|257|c241d614b103321feab0b97191b8b99425ee361dc731116d93709a0b2625974c
casDigest|hdMetadataEnvelope|511|e7ca5037377ec67299091da9f6327f1083ba82d22d7dcb506138c2819f52743c
casDigest|hdMetadataEnvelope|512|e16d1c48353d891487fa101c7d4cb70020890d6364550d53e7e476a642054335
casDigest|hdMetadataEnvelope|513|65890da3894c621d711d80c55e5a8325a1a85b1d95319dafe1ef357d7276376c
casDigest|hdMetadataEnvelope|1023|1ee159b19a4ebb4a97cc0f11601fc553f3c2732711efdacd7249147604030b7d
casDigest|hdMetadataEnvelope|1024|5bdb1c4c8dec06c6237ad719b51ecf403ef725dbe8287bb8bddce4364db5f04a
casDigest|hdMetadataEnvelope|1025|d9677824dfbc63ffe7acc4501eb1313f40ca7a978dddfc55db22a90c4c3f74f3
casDigest|hdMetadataEnvelope|2047|5bc1d8d771a07bcd4eccc31fc219dc211fe2c2912739d1e7c7e7fd3263eb8026
casDigest|hdMetadataEnvelope|2048|f2337be2ce1848e065dc5c4e37f0baf85ce63af93ab44b57fd56483c19f6323e
casDigest|hdMetadataEnvelope|2049|2f7224383dfbcc736d8e44f42ad7151554cbb5dfc70bd69a730e3108688e1e4f
casDigest|hdMetadataEnvelope|4095|1e06a50ed7e4a4c77e6cf5406aa3c74918c185ad3ade73b2e311b0a513ee31dd
casDigest|hdMetadataEnvelope|4096|ea45d46f1d76b9b496cbd707d7b704718cb919c00397fbcb52f877d10cb972cf
casDigest|hdMetadataEnvelope|4097|a9bfc1a1a6880d74febbed93a6e4331f044ec79fcdb354f73db489f6093094d3
casDigest|hdMetadataEnvelope|8191|2747d35d3e432398a62f54429d2abbc5bac646c61879438522ce380d17592809
casDigest|hdMetadataEnvelope|8192|bdb4caa1bb9abc657623b0a0c5957e9458dc96db42f53b509f64f1d978bdb088
casDigest|hdMetadataEnvelope|8193|5d367d8f2b8230a49ef397aae92eee2fdcad9b3d0521c6db5a7bc9c5a755898b
casDigest|hdMetadataEnvelope|65535|98d74f1c1342ef1bdc0bc9da1f3f033d499abb130b697d021d41305a021e928f
casDigest|hdMetadataEnvelope|65536|aa701ab5c04fe6a8e890b5f43b86e755942f0c259bf86d6f976bd3ff23ecc283
casDigest|hdMetadataEnvelope|65537|d741354b6b47fef4e7a2bbf17f1898c046b2ad9b32ad0ce7601707714b8f31fa
blake3DomainDigest|hdCasContent|0|0915dba28f88ef86e66c924f11ab3df9fdf78980e0a9abd07f4d3779ce0266ac
blake3DomainDigest|hdCasContent|1|dd44f60f77a7167ca95ded21dec38767ee0443dd42c2504cff3838bcb5e78b4c
blake3DomainDigest|hdCasContent|63|0cf5fd7db9285f6025d38a545b6a4d301b139fda21cd44a3050e6b514f3548bf
blake3DomainDigest|hdCasContent|64|726c61a5f8b8f554595cd3eea5c58edc646755a144aa83ababe1338a1e3afd60
blake3DomainDigest|hdCasContent|65|d2be125568c071fb1eefa06a786d11066a360f0f7fc159c65e09ae80022b723e
blake3DomainDigest|hdCasContent|1024|8aac79f152fed21f9b914f6cd2277818baf6b73e60154b68a3b87c233b810a03
blake3DomainDigest|hdCasContent|4097|c76645eab41a51b3e058c5b97606f4923e58596d3867c87d8530193adb51ada1
blake3DomainDigest|hdActionFingerprint|0|78f91bcc7d5f243f9c4797c65d427102d2e17f14d07bdce546ba1372322768b5
blake3DomainDigest|hdActionFingerprint|1|0bbef65e4c6206b6df8fe615bea80072003f21643860c991d2f7714b3aed52b1
blake3DomainDigest|hdActionFingerprint|63|555e95132a9b1c5c0d7d6f5166d84c176757c31683fa5c255e740da219037d0a
blake3DomainDigest|hdActionFingerprint|64|29241b8934f75faaf29f05da803673a9b40490023ec3167338310c5bad45a672
blake3DomainDigest|hdActionFingerprint|65|2000326e2a3229bd1010ec927d579f9128053f9938004a2464eaef36e10a6919
blake3DomainDigest|hdActionFingerprint|1024|ca00403c898df4fb355c53b84b65dd31024e7e97bde971c414eaab87c783fcef
blake3DomainDigest|hdActionFingerprint|4097|7f6fd3f282a8a728d6d6274caf9e17f13d81f069c6dae7c13ca3337464d0749f
blake3DomainDigest|hdMetadataEnvelope|0|9aa69fb0025f8eb6f8492b26a2dbb086fdc3ee22725b2889175c0835a95fd8d3
blake3DomainDigest|hdMetadataEnvelope|1|4f87647bacc73080277405b05cab02b234e0059235716443dfb4f71e1dccd9b7
blake3DomainDigest|hdMetadataEnvelope|63|ba823379abd737d65cb255ebadb0df9f7c030ff562d2fa3a429b828953319cd2
blake3DomainDigest|hdMetadataEnvelope|64|86acda67173f5a4bdd5bf970bab0bb1e283ba21eefa05278168d602b548ace91
blake3DomainDigest|hdMetadataEnvelope|65|f6430d4607c2462b6d261194aa414576e174924f83a92b095a014e555247a030
blake3DomainDigest|hdMetadataEnvelope|1024|d70ad22cc18dc75def61fd6e76e1966a9162ea25a381e1dffcd5d082e0182f72
blake3DomainDigest|hdMetadataEnvelope|4097|1385a85503fa8f2cecd622312d196d404ba7af5a44a085f0444c10a73144cf70
localHash|0|0883b62ed51490c3
localHash|1|877448ac5b7b30c7
localHash|2|eda15c26312bcaeb
localHash|7|3c3c6c4dde6902fb
localHash|8|11a5270b18a60552
localHash|9|b9f16fa527cfd143
localHash|15|375c6c9bb365141a
localHash|16|e44e90846a3f313e
localHash|17|3c7666818ba0430c
localHash|31|dd9c901a5c540a21
localHash|32|13959999bcbe5541
localHash|33|7e3b2ab6a6fa8721
localHash|63|608968400d069766
localHash|64|e4143d02ab6c05b5
localHash|65|529d8fc398ab1b15
localHash|127|a70d964796e88c3c
localHash|128|b1957c45243df7d2
localHash|129|8300485b9bc069cd
localHash|255|a9f7574edacaad04
localHash|256|3be2bad57d4d9095
localHash|257|50f87d2ae597ba3c
localHash|511|452acceb5d368181
localHash|512|760a24a791b21d50
localHash|513|b421d37f0d0d6876
localHash|1023|498a85d225974485
localHash|1024|a17367172a7e5b71
localHash|1025|9cbdec155c3624a8
localHash|2047|a89d73f7dbf9ef1a
localHash|2048|c9280a9ed68a8796
localHash|2049|af8ee3b507554375
localHash|4095|a5b616966e2ba8b9
localHash|4096|d40fecf1737d995c
localHash|4097|f03b512758bf8d86
localHash|8191|a70ae7d1243e6fcc
localHash|8192|842fcbd8daba58af
localHash|8193|5171913bb445d939
localHash|65535|77aaffd86f55d5fe
localHash|65536|09d9eeeaca66384f
localHash|65537|17d2ac7db8759c4a
"""

type Row = object
  kind: string
  domain: string
  size: int
  expected: string

proc baselineRows(): seq[Row] =
  for rawLine in Baseline.splitLines():
    let line = rawLine.strip()
    if line.len == 0: continue
    let parts = line.split('|')
    case parts.len
    of 4:
      result.add(Row(kind: parts[0], domain: parts[1],
                     size: parseInt(parts[2]), expected: parts[3]))
    of 3:
      result.add(Row(kind: parts[0], domain: "", size: parseInt(parts[1]),
                     expected: parts[2]))
    else:
      raise newException(ValueError, "malformed baseline row: " & line)

suite "hash policy frame bytes are pinned":

  let rows = baselineRows()

  test "the baseline corpus is actually present":
    # Guards the failure mode where the corpus is emptied or mangled and the
    # comparison loops below pass by iterating nothing.
    check rows.len == 177
    check rows.countIt(it.kind == "casDigest") == 117
    check rows.countIt(it.kind == "blake3DomainDigest") == 21
    check rows.countIt(it.kind == "localHash") == 39
    for row in rows:
      check row.expected.len in {16, 64}

  test "casDigest matches the pre-change implementation byte for byte":
    var checked = 0
    for row in rows:
      if row.kind != "casDigest": continue
      let domain = parseDomain(row.domain)
      let payload = corpusPayload(row.size, ord(domain))
      check blake3.toHex(casDigest(payload, domain).bytes) == row.expected
      inc checked
    check checked == 117

  test "blake3DomainDigest matches the pre-change implementation":
    var checked = 0
    for row in rows:
      if row.kind != "blake3DomainDigest": continue
      let domain = parseDomain(row.domain)
      let payload = corpusPayload(row.size, ord(domain) + 100)
      check blake3.toHex(blake3DomainDigest(payload, domain).bytes) ==
        row.expected
      inc checked
    check checked == 21

  test "localHash matches the pre-change implementation":
    var checked = 0
    for row in rows:
      if row.kind != "localHash": continue
      let payload = corpusPayload(row.size, 42)
      check toHex(localHash(payload).value, 16).toLowerAscii() == row.expected
      inc checked
    check checked == 39

  test "every HashDomain is covered":
    # Exhaustiveness. A value added to `HashDomain` arrives with no rows and
    # fails here, rather than quietly acquiring an untested frame tag.
    var casDomains, blakeDomains: seq[string]
    for row in rows:
      if row.kind == "casDigest": casDomains.add(row.domain)
      elif row.kind == "blake3DomainDigest": blakeDomains.add(row.domain)
    casDomains = casDomains.deduplicate().sorted()
    blakeDomains = blakeDomains.deduplicate().sorted()
    for domain in HashDomain:
      if domain == hdLocalInvalidation:
        # Rejected by the CAS arms on purpose; its frame is exercised
        # through `localHash` instead, which the rows above cover.
        check casDigest(@[1'u8], hdCasContent).domain == hdCasContent
        expect ValueError:
          discard casDigest(@[1'u8], hdLocalInvalidation)
        expect ValueError:
          discard blake3DomainDigest(@[1'u8], hdLocalInvalidation)
      else:
        check $domain in casDomains
        check $domain in blakeDomains

  test "the empty payload is framed, not skipped":
    # The length field and the magic mean an empty payload still has a
    # digest, and it must differ per domain -- the cheapest way to break
    # framing is to stop emitting the header when there is nothing to hash.
    var seen: seq[string]
    for domain in HashDomain:
      if domain == hdLocalInvalidation: continue
      let d = blake3.toHex(casDigest(@[], domain).bytes)
      check d != blake3.toHex(blake3.digest(newSeq[byte](0)))
      check d notin seen
      seen.add(d)

  test "the streaming file digest agrees with the in-memory digest":
    # `casFileDigest` frames and streams the same bytes from disk. It was
    # already the streaming implementation before this change, so its
    # agreement with `casDigest` is an independent witness that the
    # in-memory path still emits the frame the file path emits.
    let dir = getTempDir() / "t_hash_policy_frame_bytes"
    createDir(dir)
    defer: removeDir(dir)
    for size in [0, 1, 64, 1024, 1024 * 1024 + 1]:
      let payload = corpusPayload(size, 5)
      let path = dir / ("p" & $size & ".bin")
      # `writeFile(path, openArray[byte])` indexes element 0 unconditionally,
      # so the empty payload -- the case most worth covering -- has to go
      # through the string overload.
      if size == 0:
        writeFile(path, "")
      else:
        writeFile(path, payload)
      for domain in HashDomain:
        if domain == hdLocalInvalidation: continue
        check blake3.toHex(casFileDigest(path, uint64(size), domain).bytes) ==
          blake3.toHex(casDigest(payload, domain).bytes)
