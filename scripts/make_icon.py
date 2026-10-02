#!/usr/bin/env python3
"""Render the app's simple geometric display mark without external tools."""
import json
from pathlib import Path
import struct
import zlib

root = Path(__file__).resolve().parents[1] / 'EInk' / 'Assets.xcassets'
root.mkdir(parents=True, exist_ok=True)
(root / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}) + '\n')
icon = root / 'AppIcon.appiconset'
icon.mkdir(exist_ok=True)
size = 1024
pixels = bytearray([242, 243, 236] * size * size)

def rectangle(x, y, w, h, color):
    for row in range(y, y+h):
        start = (row*size+x)*3
        pixels[start:start+w*3] = bytes(color)*w

rectangle(164, 232, 696, 520, (60, 99, 91))
rectangle(205, 273, 614, 438, (242, 243, 236))
rectangle(262, 334, 208, 36, (60, 99, 91))
rectangle(262, 404, 140, 20, (60, 99, 91))
rectangle(262, 483, 498, 5, (60, 99, 91))
rectangle(262, 539, 56, 56, (60, 99, 91))
rectangle(353, 544, 288, 15, (60, 99, 91))
rectangle(353, 580, 208, 15, (60, 99, 91))
rectangle(262, 641, 380, 7, (60, 99, 91))
for y in range(328, 433):
    for x in range(650, 755):
        if (x-702)**2 + (y-380)**2 < 44**2:
            offset = (y*size+x)*3
            pixels[offset:offset+3] = bytes((60, 99, 91))

def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind+data))

rows = b''.join(b'\x00'+pixels[y*size*3:(y+1)*size*3] for y in range(size))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', size, size, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
(icon/'AppIcon.png').write_bytes(png)
(icon/'Contents.json').write_text(json.dumps({'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2)+'\n')
accent = root/'AccentColor.colorset'
accent.mkdir(exist_ok=True)
(accent/'Contents.json').write_text(json.dumps({'colors': [{'idiom': 'universal', 'color': {'color-space': 'srgb', 'components': {'red': '0.24', 'green': '0.43', 'blue': '0.40', 'alpha': '1.0'}}}], 'info': {'author': 'xcode', 'version': 1}}, indent=2)+'\n')
