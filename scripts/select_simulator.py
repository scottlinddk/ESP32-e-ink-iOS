#!/usr/bin/env python3
"""Select an available iPhone runtime compatible with the selected Xcode SDK."""
import argparse
import json
import re
import sys


def select_simulator(payload, max_ios=None, prefer_booted=False, fallback_id=None):
    ceiling = tuple(map(int, max_ios.split("."))) if max_ios else (999,)
    ceiling = ceiling + (0,) * (3 - len(ceiling))
    candidates = []
    for runtime, entries in payload["devices"].items():
        match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        if version < (17, 0, 0) or version > ceiling:
            continue
        for device in entries:
            name = device["name"]
            if not device.get("isAvailable") or not re.search(r"\biPhone\b", name):
                continue
            model = re.search(r"iPhone (\d+)", name)
            number = int(model[1]) if model else 0
            regular_pro = " Pro" in name and "Max" not in name
            regular_size = "Max" not in name and "Plus" not in name
            original = not name.startswith("Clone ")
            rank = (version, number, regular_pro, regular_size, original, name, device["udid"])
            candidates.append((rank, device.get("state") == "Booted"))
    if not candidates:
        raise ValueError("No available iPhone simulator supports iOS 17 through the selected Xcode SDK version.")
    if prefer_booted:
        booted = [candidate for candidate in candidates if candidate[1]]
        test_clones = [candidate for candidate in booted if not candidate[0][4]]
        fallback = [candidate for candidate in candidates if candidate[0][-1] == fallback_id]
        candidates = test_clones or booted or fallback or candidates
    rank, _ = max(candidates)
    *_, name, identifier = rank
    return name, identifier


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-ios", help="highest supported runtime, from xcrun --sdk iphonesimulator --show-sdk-version")
    parser.add_argument("--prefer-booted", action="store_true", help="reuse XCTest's booted iPhone clone for screenshots")
    parser.add_argument("--fallback-id", help="original simulator to use when no compatible iPhone is booted")
    parser.add_argument("--id-only", action="store_true", help="print only the simulator identifier")
    args = parser.parse_args()
    try:
        name, identifier = select_simulator(json.load(sys.stdin), args.max_ios, args.prefer_booted, args.fallback_id)
    except ValueError as error:
        parser.exit(1, f"{error}\n")
    print(f"Selected {name} ({identifier})", file=sys.stderr)
    print(identifier if args.id_only else f"SIMULATOR_ID={identifier}")


if __name__ == "__main__":
    main()
