#!/usr/bin/env python3
"""Portable project checks. Swift compilation and XCTest run on macOS CI."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root/'scripts/generate_project.py'), '--check'], check=True)
for path in list(root.glob('Config/*.plist')) + list(root.glob('Config/*.entitlements')) + list(root.glob('EInk/*.xcprivacy')):
    with path.open('rb') as source:
        plistlib.load(source)
for path in root.glob('EInk/**/*.json'):
    json.loads(path.read_text())
for path in root.glob('EInk.xcodeproj/**/*.xcscheme'):
    ET.parse(path)
with (root/'Config/Info.plist').open('rb') as source:
    info = plistlib.load(source)
assert info['EInkServerURL'].startswith('https://')
assert info['ClerkPublishableKey'].startswith(('pk_live_', 'pk_test_'))
assert 'NSBluetoothAlwaysUsageDescription' in info
assert 'UIBackgroundModes' not in info, 'Bluetooth transfers are explicitly foreground only'
assert (root/'EInk/Assets.xcassets/AppIcon.appiconset/AppIcon.png').read_bytes().startswith(b'\x89PNG')
print('Project references, property lists, privacy manifest and assets are valid.')
