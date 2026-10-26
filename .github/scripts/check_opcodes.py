#!/usr/bin/env python3
"""Guard the opcode policy: the destructive commands must stay unreachable.

A wrong opcode on protocol v2 is not harmless, so the policy in SonyLink.swift is checked
here rather than trusted. Two kinds of rule:

  * Blanket-forbidden opcodes (reboot, power off, firmware, json) must be in `forbidden`
    and never in `allowed`.
  * SYSTEM_SET_PARAM (0xF8) is type-aware, NOT blanket-forbidden: the one opcode carries
    both speak-to-chat and RESET_SETTINGS 0x09 (factory reset), told apart by the inquired
    type byte. It must never be blanket-allowed, the factory-reset type must not be a
    permitted speak-to-chat type, and the send path must route through `Sony.permits`.
"""
import re
import sys

SOURCE = "Sources/Core/SonyLink.swift"

# Opcodes with no legitimate use here: must be denied outright.
DESTRUCTIVE = {
    0x98: "system control / reboot",
    0x24: "power off",
    0x2D: "large data / firmware",
    0xC4: "json dump",
}
FACTORY_RESET_TYPE = 0x09  # RESET_SETTINGS, a SYSTEM inquired type — must never be reachable


def read_set(text: str, name: str) -> set[int]:
    match = re.search(rf"static let {name}: Set<UInt8> = \[(.*?)\]", text, re.S)
    if not match:
        sys.exit(f"FAIL: could not find the '{name}' set in {SOURCE}")
    return {int(v, 16) for v in re.findall(r"0x([0-9a-fA-F]{2})", match.group(1))}


text = open(SOURCE).read()
allowed = read_set(text, "allowed")
forbidden = read_set(text, "forbidden")
smart_talking = read_set(text, "smartTalkingTypes")

print(f"allowed       ({len(allowed)}): {' '.join(f'{o:02X}' for o in sorted(allowed))}")
print(f"forbidden     ({len(forbidden)}): {' '.join(f'{o:02X}' for o in sorted(forbidden))}")
print(f"smartTalking  ({len(smart_talking)}): {' '.join(f'{o:02X}' for o in sorted(smart_talking))}")

failures = []

for opcode, what in DESTRUCTIVE.items():
    if opcode in allowed:
        failures.append(f"0x{opcode:02X} ({what}) is on the allow list")
    if opcode not in forbidden:
        failures.append(f"0x{opcode:02X} ({what}) is missing from the deny list")

overlap = allowed & forbidden
if overlap:
    failures.append("in both lists: " + " ".join(f"0x{o:02X}" for o in sorted(overlap)))

# SYSTEM_SET_PARAM (0xF8) and SYSTEM_SET_EXT_PARAM (0xFC) type-aware policy: neither may be
# blanket-allowed, and both are gated to speak-to-chat types that must never include reset.
for opcode, label in ((0xF8, "SYSTEM_SET_PARAM"), (0xFC, "SYSTEM_SET_EXT_PARAM")):
    if opcode in allowed:
        failures.append(f"0x{opcode:02X} ({label}) is on the blanket allow list")
if not smart_talking:
    failures.append("smartTalkingTypes is empty — the SYSTEM writes are either unreachable or ungated")
if FACTORY_RESET_TYPE in smart_talking:
    failures.append(f"0x{FACTORY_RESET_TYPE:02X} (factory reset) is a permitted speak-to-chat type")
if "op == systemSetParam || op == systemSetExtParam" not in text or "smartTalkingTypes.contains" not in text:
    failures.append("the type-aware SYSTEM-write gate is missing from permits()")

# the guard itself must route every send through permits()
if "Sony.permits(payload)" not in text:
    failures.append("the send path no longer routes through Sony.permits")

for f in failures:
    print(f"FAIL: {f}")
sys.exit(1 if failures else 0)
