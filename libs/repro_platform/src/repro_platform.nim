type
  HostPlatform* = object
    os*: string
    cpu*: string

proc currentHost*(): HostPlatform =
  HostPlatform(os: hostOS, cpu: hostCPU)
