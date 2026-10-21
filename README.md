# Hush

Menu bar control for Sony WH-1000XM6 headphones on macOS.

Sony's Sound Connect app is iPhone-only, so on a Mac there is no way to change noise
cancelling, read the battery or toggle DSEE. Hush talks to the headphones directly over
Bluetooth RFCOMM using Sony's own MDR protocol.

<img src="docs/screenshot.png" width="316" alt="Hush panel">

## What it does

- **Noise cancelling** — Off / Noise Cancelling / Ambient Sound, ambient level 0–20, Focus on Voice
- **Battery**, active **codec**, **firmware version**
- **DSEE Extreme** toggle
- **Now Playing** — artwork, title, artist, and transport that works with any player, browsers included
- **Volume**, kept in step with the system volume

No Dock icon, no login item, no network access.

## Requirements

- Apple Silicon Mac, macOS 14 or later
- Headphones paired and connected in macOS Bluetooth
- Xcode command line tools to build (`xcode-select --install`)

Built and verified against a WH-1000XM6 on firmware 3.1.5. Other Sony headsets that speak
MDR protocol v2 (XM4, XM5, LinkBuds) may work, but none has been tested.

## Install

```sh
git clone https://github.com/ismoilovdevml/hush.git
cd hush
./build.sh install
open ~/Applications/Hush.app
```

`./build.sh` alone builds to `build/Hush.app` without installing.

The app is ad-hoc signed, so macOS will warn the first time: right-click → Open.

## How it works

### Finding the channel

The headphones advertise 23 SDP service records. The one that matters is Sony's control
service, UUID `956c7b26-d49a-4ba8-b03f-b17d393cb6e2`, on **RFCOMM channel 9**. macOS can
open it with `IOBluetoothDevice.openRFCOMMChannelSync` while the headset is connected for
audio — no extra permission is needed.

### Frame format

```
0x3E | dataType | seq | length (4B, big endian) | payload | checksum | 0x3C
```

`checksum` is the sum of every byte from `dataType` through the payload, masked to 8 bits.
Inside the frame, the bytes `0x3E`, `0x3C` and `0x3D` are escaped as `0x3D` followed by
the byte with bit 5 cleared.

Two rules are easy to miss and break everything if you get them wrong:

1. **Every received frame must be acknowledged** with `dataType 0x01` and
   `seq = 1 - received_seq`, or the headset retransmits the same frame about five times.
2. **The link is strictly request/response.** The sequence bit flips on each exchange, so
   sending several commands at once makes all but the first disappear. `SonyLink` keeps a
   queue with exactly one request in flight.

### Ambient sound control on the XM6

Gadgetbridge sends the ambient-sound inquiry with sub-type `0x15` (or `0x17` on devices
with wind noise reduction). On the WH-1000XM6 **neither works**: `0x15` and `0x22` get no
reply at all, and `0x17` answers once with a stale all-zero payload that never tracks the
real state. The sub-type that actually round-trips is **`0x19`**:

```
GET     0x66 0x19
RET     0x67 0x19 0x01 <on> <ambient> <focusOnVoice> <level> 0x00 0x00
SET     0x68 0x19 0x01 <on> <ambient> <focusOnVoice> <level>
NOTIFY  0x69 0x19 ...                       (echoes the new state)
```

`on=0` is Off, `on=1, ambient=0` is Noise Cancelling, `on=1, ambient=1` is Ambient Sound.
This is probably why Gadgetbridge still marks the XM6 as experimental.

### Now Playing

Since macOS 15.4, MediaRemote returns nothing to an unentitled process —
`MRMediaRemoteGetNowPlayingInfo` gave `nil` for two solid minutes here while Control Center
was showing the track. `/usr/bin/perl` is Apple-signed and entitled, so Hush bundles
[mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), which loads a small
framework inside perl and streams newline-delimited JSON back.

Transport commands go through the same path, which is why Hush needs **no Accessibility
permission**. Synthetic media keys are kept only as a fallback if that path ever closes.

## Not doing that

The headphones are not a toy, and a wrong opcode on protocol v2 is not harmless: `0xF8` is
`AUTOMATIC_POWER_OFF_BUTTON_MODE_SET` on v1 but **`FACTORY_RESET_SET`** on v2. `SonyLink`
therefore refuses to transmit anything outside an explicit allow list, before it reaches
the air:

| Allowed | `00` `04` `12` `22` `56`(read) `66` `68` `A6`(read) `E6` `E8` `F6`(read) |
|---|---|
| **Never sent** | **`F8`** factory reset · **`98`** reboot · **`24`** power off · **`2D`** firmware transfer · **`C4`** JSON dump · **`58`** EQ write |

Firmware update is not implemented and will not be. Use Sound Connect on a phone for that.

## Known limits

- **Equalizer is read-only.** The XM6 answers `0x56 0x00` with **ten** bands, while
  Gadgetbridge's decoder expects clear bass plus five. The band encoding has not been
  worked out, so Hush does not write EQ.
- **Speak-to-chat is read-only** — it reads fine on `0xF6 0x05`, but writing it goes
  through `0xF8`, which is factory reset on this protocol version.
- **No LDAC.** macOS negotiated AAC with this headset; Hush reports the codec but cannot
  change it.
- **Apple Silicon only** — `build.sh` targets `arm64`. Adding `x86_64` is a one-line change
  if someone needs it.
- Ad-hoc signing means the signature changes on every build. Nothing depends on it today,
  but if you re-enable the media-key fallback, its Accessibility grant will need regranting
  after each rebuild.

## Credits

The protocol was not guessed. The opcode tables and the ACK rule come from reading
[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) (AGPL-3.0), and the frame
markers from [SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient)
(MIT). Now Playing is possible thanks to
[mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause), which
is bundled. See [THIRD-PARTY.md](THIRD-PARTY.md).

## License

MIT — see [LICENSE](LICENSE).

Sony, WH-1000XM6 and Sound Connect are trademarks of Sony Group Corporation. This project
is not affiliated with or endorsed by Sony.
