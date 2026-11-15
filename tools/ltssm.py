#!/usr/bin/env python3
"""Print the A733 PCIe root port's LTSSM state and link-up bit (run as root).

Reads only the DesignWare port-logic debug registers at DBI 0x06000000 + 0x728/0x72c.
  0x00 Detect.Quiet   0x03 Polling.Compliance (far end detected, never transmits)
  0x11 L0 (link up)
Do not widen the mapping to undocumented ranges: that hung the board once.
"""
import mmap, os, struct

DBI = 0x06000000
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=DBI)
r = lambda o: struct.unpack("<I", m[o:o + 4])[0]
print("LTSSM=0x%02x linkup=%d" % (r(0x728) & 0x3F, (r(0x72C) >> 4) & 1))
