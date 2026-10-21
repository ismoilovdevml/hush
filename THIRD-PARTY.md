# Third-party components

## mediaremote-adapter — bundled

`vendor/mediaremote-adapter/` contains a copy of
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter),
used to read Now Playing metadata and send transport commands. The adapter's
sources are compiled into `MediaRemoteAdapter.framework` by `build.sh` and
shipped inside `Hush.app`, together with `mediaremote-adapter.pl`.

Licensed under the BSD 3-Clause License, Copyright (c) 2025 Jonas van den Berg
and contributors. The full text is kept at
`vendor/mediaremote-adapter/LICENSE` and is distributed with the app.

## Protocol references — read, not copied

No code from either project is present in this repository; they were read to
learn the wire format, and the Swift implementation here was written from
those facts.

- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) (AGPL-3.0) —
  the Sony MDR payload/opcode tables (`PayloadTypeV1`, `PayloadTypeV2`) and the
  ACK sequence rule.
- [SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient)
  (MIT) — the frame markers and `DATA_TYPE` values.

Sony, WH-1000XM6 and Sound Connect are trademarks of Sony Group Corporation.
This project is not affiliated with or endorsed by Sony.
