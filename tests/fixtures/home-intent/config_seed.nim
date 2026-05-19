import repro/profile

profile "frank":
  activity default:
    git

  activity photography:
    darktable
    exiftool

  hosts:
    "dev-laptop": [photography]
