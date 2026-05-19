import repro/profile

profile "bob":
  activity develop_software:
    git
    gh

  hosts:
    "dev-laptop": [develop_software]
