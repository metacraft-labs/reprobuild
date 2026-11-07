systemd.systemUnit {
  name = "kept.service"
  content = "[Unit]
Description=x

[Service]
User=a
ExecStart=/repro/store/prefixes/svc/1.0/bin/svc

[Install]
WantedBy=multi-user.target
"
  hardening = "serviceFloor"
  stateDirectories = [
    "keep:/var/lib/kept"
  ]
}
