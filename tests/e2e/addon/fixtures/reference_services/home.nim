## The host registry the full realisation of the reference activities reads
## (beside `system.nim`): the parity gate's full guest (host name `addon-tb`)
## selects both reference activities, realised in full.

import repro_profile

profile "referenceServicesRegistry":
  hosts:
    "addon-tb":
      system: {mode: full, activities: [vaultwarden, ethereum_validator]}
