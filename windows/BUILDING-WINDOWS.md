# hush-windows — build & status

A Windows port of the Hush macOS Sony WH-1000XM6 app. Same protocol, Windows transport + UI.

## Layout

| Project | What | Where it builds/runs | Verified |
|---|---|---|---|
| `Hush.Protocol` | pure MDR protocol: frame codec, commands, opcode guard | any OS (net10.0) | **yes** |
| `Hush.Protocol.Tests` | 19 xUnit tests mirroring the macOS suite | any OS | **yes — 19/19 on macOS** |
| `Hush.Bluetooth` | WinRT RFCOMM transport (SonyLink) | Windows 10 2004+ only | compiles clean on macOS¹; runtime not tested |
| `Hush.Cli` | `hush` console harness (status / anc / dsee) | Windows only | compiles clean on macOS¹; runtime not tested |
| `Hush.App` | tray app: WinForms NotifyIcon + WebView2 flyout (`flyout.html`/`.js`) wired to the transport | Windows only | compiles clean on macOS¹; runtime not tested |

## Verify the portable core (any OS, incl. macOS)

```
dotnet test Hush.Protocol.Tests/Hush.Protocol.Tests.csproj
```
No headset, no Windows needed. This proves the frame format, the ANC/EQ/speak-to-chat/noise-adaptive
builders, and the opcode guard are byte-for-byte correct.

## Build & run on Windows

Prereqs: Windows 10 build 19041 (2004) or newer, .NET 10 SDK. Pair the WH-1000XM6 first.

```
dotnet run --project Hush.Cli -- status
dotnet run --project Hush.Cli -- anc ambient
dotnet run --project Hush.Cli -- dsee on
```

The tray app (icon near the clock → click for the flyout):

```
dotnet run --project Hush.App
```
Needs the WebView2 Runtime (preinstalled on Windows 11; on Windows 10 install the Evergreen
runtime from Microsoft). v1 covers ANC, EQ preset, DSEE, battery/codec/firmware. Now-playing and
system volume are not wired yet.

¹ The Windows-TFM projects (`Hush.Bluetooth`, `Hush.Cli`) don't *run* on macOS, but they
**compile** there against the Windows reference assemblies, which type-checks all the WinRT API
usage without a Windows box:

```
dotnet build Hush.Cli/Hush.Cli.csproj -p:EnableWindowsTargeting=true
```

For a runnable binary, build on Windows (Visual Studio / `dotnet` on Windows).

## Testing reality

This was written on a Mac. The protocol core is proven here; the Bluetooth path is **not yet tested
on a live headset**. To test it:

- A **Windows 11 ARM VM** (Parallels/UTM on Apple Silicon) runs the UI and app logic, **but classic
  Bluetooth RFCOMM is not passed through to the VM by default** — the VM cannot reach the Mac's
  built-in Bluetooth for SPP.
- For real headset BT in a VM, pass a **USB Bluetooth dongle** through to the VM (pair the XM6 inside
  Windows). Otherwise use real Windows hardware.

Treat every `anc`/`dsee` write as unverified until it has moved the real headset on Windows.
