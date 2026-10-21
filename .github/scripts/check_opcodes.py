#!/usr/bin/env python3
"""Guard the opcode policy: the destructive commands must stay unreachable.

A wrong opcode on protocol v2 is not harmless - 0xF8 is FACTORY_RESET_SET - so the
allow/deny lists in SonyLink.swift are checked here rather than trusted.
"""
import re
import sys

SOURCE = "Sources/SonyLink.swift"
DESTRUCTIVE = {
    0xF8: "factory reset",
    0x98: "system control / reboot",
    0x24: "power off",
    0x2D: "large data / firmware",
    0xC4: "json dump",
}


def read_set(text: str, name: str) -> set[int]:
    match = re.search(rf"static let {name}: Set<UInt8> = \[(.*?)\]", text, re.S)
    if not match:
        sys.exit(f"FAIL: could not find the '{name}' set in {SOURCE}")
    return {int(v, 16) for v in re.findall(r"0x([0-9a-fA-F]{2})", match.group(1))}


text = open(SOURCE).read()
allowed = read_set(text, "allowed")
forbidden = read_set(text, "forbidden")

print(f"allowed   ({len(allowed)}): {' '.join(f'{o:02X}' for o in sorted(allowed))}")
print(f"forbidden ({len(forbidden)}): {' '.join(f'{o:02X}' for o in sorted(forbidden))}")

failures = []
for opcode, what in DESTRUCTIVE.items():
    if opcode in allowed:
        failures.append(f"0x{opcode:02X} ({what}) is on the allow list")
    if opcode not in forbidden:
        failures.append(f"0x{opcode:02X} ({what}) is missing from the deny list")

overlap = allowed & forbidden
if overlap:
    failures.append("in both lists: " + " ".join(f"0x{o:02X}" for o in sorted(overlap)))

# the guard itself must still refuse anything off the allow list
if "Sony.allowed.contains(op)" not in open(SOURCE).read():
    failures.append("the send path no longer checks the allow list")

for f in failures:
    print(f"FAIL: {f}")
sys.exit(1 if failures else 0)
