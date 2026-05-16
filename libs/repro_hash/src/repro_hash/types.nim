type
  HashAlgorithm* = enum
    haBlake3_256
    haGxHash64
    haXxh3_64

  HashDomain* = enum
    hdCasContent
    hdActionFingerprint
    hdLocalInvalidation
    hdMetadataEnvelope

  ContentDigest* = object
    algorithm*: HashAlgorithm
    domain*: HashDomain
    bytes*: array[32, byte]

  LocalInvalidationHash* = object
    algorithm*: HashAlgorithm
    domain*: HashDomain
    value*: uint64

  LocalHashSelection* = object
    algorithm*: HashAlgorithm
    implementation*: string
    reason*: string
