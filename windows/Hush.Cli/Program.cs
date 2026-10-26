using System.Text;
using Hush.Bluetooth;
using Hush.Protocol;

// hush CLI (Windows). Proves the RFCOMM transport + the portable protocol core against a real
// headset. NOT YET VERIFIED on a live device — run this on Windows (or a VM with a USB Bluetooth
// dongle) with the XM6 paired and connected.
//
//   hush                      -> status
//   hush status
//   hush anc <off|nc|ambient>
//   hush dsee <on|off>

const byte DT = OpcodePolicy.Cmd1;

string cmd = args.Length > 0 ? args[0].ToLowerInvariant() : "status";

string? id = await SonyLink.FindDeviceIdAsync();
if (id is null)
{
    Console.Error.WriteLine("No paired Sony headset advertising the SPP service was found.");
    return 1;
}

using var link = new SonyLink();
if (!await link.ConnectAsync(id))
{
    Console.Error.WriteLine("Could not open the RFCOMM channel (headset connected? not held by another app?).");
    return 1;
}

async Task<byte?> ProbeAmbientTypeAsync()
{
    foreach (var t in SonyCommand.AmbientTypes)
    {
        var r = await link.RequestAsync(DT, SonyCommand.AmbientGet(t), 0x67);
        if (r is { Length: > 1 } && r[1] == t) return t;
    }
    return null;
}

switch (cmd)
{
    case "status":
    {
        var fw = await link.RequestAsync(DT, new byte[] { 0x04, 0x02 }, 0x05);
        if (fw is { Length: > 3 })
            Console.WriteLine($"firmware : {Encoding.UTF8.GetString(fw, 3, fw.Length - 3)}");

        var bat = await link.RequestAsync(DT, new byte[] { 0x22, 0x00 }, 0x23);
        if (bat is { Length: >= 4 })
            Console.WriteLine($"battery  : {bat[2]}%{(bat[3] == 1 ? " (charging)" : "")}");

        var codec = await link.RequestAsync(DT, new byte[] { 0x12, 0x02 }, 0x13);
        if (codec is { Length: >= 3 })
        {
            var names = new Dictionary<byte, string>
            { [0x01] = "SBC", [0x02] = "AAC", [0x10] = "LDAC", [0x20] = "aptX", [0x21] = "aptX HD" };
            Console.WriteLine($"codec    : {(names.TryGetValue(codec[2], out var nm) ? nm : $"0x{codec[2]:x2}")}");
        }

        if (await ProbeAmbientTypeAsync() is { } t)
        {
            var anc = await link.RequestAsync(DT, SonyCommand.AmbientGet(t), 0x67);
            if (anc != null && SonyCommand.ParseAmbient(anc) is { } p)
            {
                var extra = p.Mode == SonyCommand.AmbientMode.Ambient
                    ? $" (level {p.Level}{(p.FocusOnVoice ? ", focus on voice" : "")})" : "";
                Console.WriteLine($"anc      : {p.Mode}{extra}");
            }
        }
        return 0;
    }

    case "anc":
    {
        if (args.Length < 2) { Console.Error.WriteLine("usage: hush anc <off|nc|ambient>"); return 2; }
        SonyCommand.AmbientMode? mode = args[1].ToLowerInvariant() switch
        {
            "off" => SonyCommand.AmbientMode.Off,
            "nc" or "noise" => SonyCommand.AmbientMode.NoiseCancelling,
            "ambient" or "transparency" => SonyCommand.AmbientMode.Ambient,
            _ => null,
        };
        if (mode is null) { Console.Error.WriteLine("mode must be off, nc or ambient"); return 2; }

        if (await ProbeAmbientTypeAsync() is not { } type)
        {
            Console.Error.WriteLine("the headset did not answer any known ANC inquiry type");
            return 1;
        }
        var payload = SonyCommand.AmbientSet(type, mode.Value, focusOnVoice: false, level: 10);
        var reply = await link.RequestAsync(DT, payload, 0x69);
        Console.WriteLine(reply != null ? $"anc set to {mode}" : "no reply (refused, or the headset stayed quiet)");
        return reply != null ? 0 : 1;
    }

    case "dsee":
    {
        if (args.Length < 2 || (args[1] != "on" && args[1] != "off"))
        {
            Console.Error.WriteLine("usage: hush dsee <on|off>");
            return 2;
        }
        bool on = args[1] == "on";
        var reply = await link.RequestAsync(DT, new byte[] { 0xE8, 0x01, (byte)(on ? 1 : 0) }, 0xE9);
        Console.WriteLine(reply != null ? $"dsee {(on ? "on" : "off")}" : "no reply");
        return reply != null ? 0 : 1;
    }

    default:
        Console.Error.WriteLine($"unknown command '{cmd}' — try: status | anc <off|nc|ambient> | dsee <on|off>");
        return 2;
}
