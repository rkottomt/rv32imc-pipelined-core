#!/usr/bin/env python3
"""elf2hex.py <elf> <out.hex> [words] - RAM image ($readmemh format) for synthesis."""
import struct, sys
elf, out = sys.argv[1], sys.argv[2]
words = int(sys.argv[3]) if len(sys.argv) > 3 else 1 << 14
d = open(elf, 'rb').read()
img = bytearray(words * 4)
phoff, = struct.unpack_from('<I', d, 28)
phentsize, phnum = struct.unpack_from('<HH', d, 42)
for i in range(phnum):
    t, off, va, pa, fsz, msz = struct.unpack_from('<IIIIII', d, phoff + i * phentsize)
    if t == 1 and pa < len(img):
        img[pa:pa + fsz] = d[off:off + fsz]
with open(out, 'w') as f:
    for i in range(words):
        f.write('%08x\n' % struct.unpack_from('<I', img, 4 * i))
