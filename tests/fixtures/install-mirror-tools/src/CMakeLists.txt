cmake_minimum_required(VERSION 3.24)
project(MirrorProbe NONE)
install(PROGRAMS mirror-probe DESTINATION bin)
install(FILES mirror-probe.pc DESTINATION lib/pkgconfig)
