using System.Text.Json;
using Microsoft.Web.WebView2.WinForms;
using Hush.Bluetooth;
using Hush.Protocol;

namespace Hush.App;

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext());
    }
}

/// Tray icon + the flyout window it toggles. A left click near the clock shows the flyout; it
/// hides when it loses focus, like a native Windows tray flyout.
sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _icon;
    private readonly FlyoutForm _flyout = new();

    public TrayContext()
    {
        _icon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "Hush — WH-1000XM6",
            Visible = true,
        };
        _icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) _flyout.Toggle(); };

        var menu = new ContextMenuStrip();
        menu.Items.Add("Open", null, (_, _) => _flyout.Toggle());
        menu.Items.Add("Quit", null, (_, _) => ExitThread());
        _icon.ContextMenuStrip = menu;
    }

    protected override void ExitThreadCore()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _flyout.Dispose();
        base.ExitThreadCore();
    }
}

/// Borderless WebView2 host for flyout.html. All headphone I/O goes through HeadphoneBridge; the
/// page talks to it with postMessage, and gets state back the same way.
sealed class FlyoutForm : Form
{
    private readonly WebView2 _web = new();
    private readonly HeadphoneBridge _bridge = new();
    private bool _ready;

    public FlyoutForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Width = 380;
        Height = 640;
        BackColor = Color.FromArgb(15, 27, 46);
        Controls.Add(_web);
        _web.Dock = DockStyle.Fill;
        Deactivate += (_, _) => Hide();
    }

    public async void Toggle()
    {
        if (Visible) { Hide(); return; }
        if (!_ready) await InitAsync();
        PositionNearTray();
        Show();
        Activate();
        await PushStateAsync(); // refresh on every open
    }

    private async Task InitAsync()
    {
        await _web.EnsureCoreWebView2Async();
        _web.CoreWebView2.WebMessageReceived += OnMessage;
        _web.DefaultBackgroundColor = Color.Transparent;
        string html = Path.Combine(AppContext.BaseDirectory, "flyout.html");
        _web.CoreWebView2.Navigate(new Uri(html).AbsoluteUri);
        _ready = true;
    }

    private void PositionNearTray()
    {
        var wa = Screen.PrimaryScreen!.WorkingArea;
        Left = wa.Right - Width - 12;
        Top = wa.Bottom - Height - 12;
    }

    private async void OnMessage(object? sender, Microsoft.Web.WebView2.Core.CoreWebView2WebMessageReceivedEventArgs e)
    {
        string json;
        try { json = e.TryGetWebMessageAsString(); } catch { return; }
        await _bridge.HandleAsync(json);
        await PushStateAsync();
    }

    private async Task PushStateAsync()
    {
        if (!_ready) return;
        string state = await _bridge.BuildStateJsonAsync();
        _web.CoreWebView2.PostWebMessageAsString(state);
    }
}

/// Owns the RFCOMM link and turns UI commands into MDR exchanges. Reconnects lazily. All the wire
/// logic is the shared, unit-tested Hush.Protocol core; this only sequences reads and writes.
sealed class HeadphoneBridge
{
    private const byte DT = OpcodePolicy.Cmd1;

    private static readonly (byte Code, string Name)[] AllPresets =
    {
        (0x00, "Off"), (0x01, "Rock"), (0x02, "Pop"), (0x03, "Jazz"), (0x04, "Dance"),
        (0x05, "EDM"), (0x06, "R&B"), (0x07, "Acoustic"), (0x10, "Bright"), (0x11, "Excited"),
        (0x12, "Mellow"), (0x13, "Relaxed"), (0x14, "Vocal"), (0x15, "Treble Boost"),
        (0x16, "Bass Boost"), (0x17, "Speech"), (0x20, "Gaming"), (0x30, "Heavy"),
        (0x31, "Clear"), (0x32, "Hard"), (0x33, "Soft"), (0xA0, "Manual"),
        (0xA1, "User 1"), (0xA2, "User 2"), (0xA3, "User 3"),
    };

    private SonyLink? _link;
    private bool _connected;
    private byte? _ambientType;
    private byte? _eqType;
    private int _eqCenter = 6;

    // last-known state
    private string _name = "WH-1000XM6", _codec = "", _firmware = "—";
    private int? _battery;
    private bool _charging, _dsee, _focusOnVoice;
    private SonyCommand.AmbientMode _anc = SonyCommand.AmbientMode.Off;
    private int _ambientLevel = 10;
    private byte _eqPreset = 0x00;
    private int[] _eqBands = new int[10];
    private string[] _eqFrequencies = { "31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k" };
    private (byte Code, string Name)[] _eqPresets = AllPresets;

    private async Task<bool> EnsureConnectedAsync()
    {
        if (_connected && _link is { IsConnected: true }) return true;
        _link?.Dispose();
        _link = new SonyLink();
        string? id = await SonyLink.FindDeviceIdAsync();
        if (id is null) { _connected = false; return false; }
        _connected = await _link.ConnectAsync(id);
        return _connected;
    }

    private async Task<byte?> ProbeAmbientTypeAsync()
    {
        if (_ambientType is { } t) return t;
        foreach (var type in SonyCommand.AmbientTypes)
        {
            var r = await _link!.RequestAsync(DT, SonyCommand.AmbientGet(type), 0x67);
            if (r is { Length: > 1 } && r[1] == type) { _ambientType = type; return type; }
        }
        return null;
    }

    private async Task<byte?> ProbeEqTypeAsync()
    {
        if (_eqType is { } t) return t;
        foreach (var type in SonyCommand.EqualizerTypes)
        {
            var cap = await _link!.RequestAsync(DT, SonyCommand.EqualizerCapabilityGet(type), 0x51);
            if (cap != null && SonyCommand.ParseEqualizerCapability(cap) is { } c)
            {
                _eqType = type;
                _eqCenter = SonyCommand.Center(c.LevelSteps);
                _eqPresets = c.Presets.Select(code =>
                    (code, AllPresets.FirstOrDefault(p => p.Code == code).Name ?? $"0x{code:X2}")).ToArray();
                var bandsInfo = await _link!.RequestAsync(DT, SonyCommand.EqualizerBandsGet(type), 0x5B);
                if (bandsInfo != null && SonyCommand.ParseEqualizerFrequencies(bandsInfo) is { } hz)
                    _eqFrequencies = hz.Select(SonyCommand.FrequencyLabel).ToArray();
                return type;
            }
        }
        return null;
    }

    public async Task RefreshAsync()
    {
        if (!await EnsureConnectedAsync()) return;

        var fw = await _link!.RequestAsync(DT, new byte[] { 0x04, 0x02 }, 0x05);
        if (fw is { Length: > 3 }) _firmware = System.Text.Encoding.UTF8.GetString(fw, 3, fw.Length - 3);

        var bat = await _link.RequestAsync(DT, new byte[] { 0x22, 0x00 }, 0x23);
        if (bat is { Length: >= 4 }) { _battery = bat[2]; _charging = bat[3] == 1; }

        var codec = await _link.RequestAsync(DT, new byte[] { 0x12, 0x02 }, 0x13);
        if (codec is { Length: >= 3 })
        {
            _codec = codec[2] switch
            { 0x01 => "SBC", 0x02 => "AAC", 0x10 => "LDAC", 0x20 => "aptX", 0x21 => "aptX HD", _ => $"0x{codec[2]:x2}" };
        }

        if (await ProbeAmbientTypeAsync() is { } at)
        {
            var anc = await _link.RequestAsync(DT, SonyCommand.AmbientGet(at), 0x67);
            if (anc != null && SonyCommand.ParseAmbient(anc) is { } p)
            { _anc = p.Mode; _ambientLevel = p.Level; _focusOnVoice = p.FocusOnVoice; }
        }

        if (await ProbeEqTypeAsync() is { } et)
        {
            var eq = await _link.RequestAsync(DT, SonyCommand.EqualizerGet(et), 0x57);
            if (eq != null && SonyCommand.ParseEqualizer(eq, _eqCenter) is { } p)
            { _eqPreset = p.Preset; _eqBands = p.Bands; }
        }

        var dsee = await _link.RequestAsync(DT, new byte[] { 0xE6, 0x01 }, 0xE7);
        if (dsee is { Length: >= 3 }) _dsee = dsee[2] == 1;
    }

    public async Task HandleAsync(string json)
    {
        JsonElement root;
        try { root = JsonDocument.Parse(json).RootElement; } catch { return; }
        string cmd = root.TryGetProperty("cmd", out var c) ? c.GetString() ?? "" : "";

        switch (cmd)
        {
            case "status":
                await RefreshAsync();
                break;

            case "anc":
                if (!await EnsureConnectedAsync()) break;
                var mode = (root.TryGetProperty("mode", out var m) ? m.GetString() : null) switch
                {
                    "off" => SonyCommand.AmbientMode.Off,
                    "nc" => SonyCommand.AmbientMode.NoiseCancelling,
                    "ambient" => SonyCommand.AmbientMode.Ambient,
                    _ => _anc,
                };
                if (root.TryGetProperty("level", out var lv) && lv.TryGetInt32(out var lvl)) _ambientLevel = lvl;
                if (await ProbeAmbientTypeAsync() is { } at2)
                {
                    var r = await _link!.RequestAsync(DT, SonyCommand.AmbientSet(at2, mode, _focusOnVoice, _ambientLevel), 0x69);
                    if (r != null && SonyCommand.ParseAmbient(r) is { } p)
                    { _anc = p.Mode; _ambientLevel = p.Level; _focusOnVoice = p.FocusOnVoice; }
                    else _anc = mode;
                }
                break;

            case "eq":
                if (!await EnsureConnectedAsync()) break;
                string presetName = root.TryGetProperty("preset", out var pn) ? pn.GetString() ?? "" : "";
                var match = AllPresets.FirstOrDefault(p => p.Name == presetName);
                if (match.Name != null && await ProbeEqTypeAsync() is { } et2)
                {
                    var r = await _link!.RequestAsync(DT, SonyCommand.EqualizerPresetSet(et2, match.Code), 0x59);
                    if (r != null && SonyCommand.ParseEqualizer(r, _eqCenter) is { } p)
                    { _eqPreset = p.Preset; _eqBands = p.Bands; }
                    else _eqPreset = match.Code;
                }
                break;

            case "dsee":
                if (!await EnsureConnectedAsync()) break;
                bool on = root.TryGetProperty("on", out var o) && o.GetBoolean();
                await _link!.RequestAsync(DT, new byte[] { 0xE8, 0x01, (byte)(on ? 1 : 0) }, 0xE9);
                _dsee = on;
                break;
        }
    }

    public Task<string> BuildStateJsonAsync()
    {
        string ancStr = _anc switch
        { SonyCommand.AmbientMode.Off => "off", SonyCommand.AmbientMode.Ambient => "ambient", _ => "nc" };

        var state = new Dictionary<string, object?>
        {
            ["type"] = "state",
            ["connected"] = _connected,
            ["name"] = _name,
            ["codec"] = _codec,
            ["firmware"] = _firmware,
            ["battery"] = _battery,
            ["charging"] = _charging,
            ["anc"] = ancStr,
            ["ambient"] = _ambientLevel,
            ["focus"] = _focusOnVoice,
            ["dsee"] = _dsee,
            ["eqPreset"] = AllPresets.FirstOrDefault(p => p.Code == _eqPreset).Name ?? $"0x{_eqPreset:X2}",
            ["eqPresets"] = _eqPresets.Select(p => p.Name).ToArray(),
            ["eqBands"] = _eqBands,
            ["eqFrequencies"] = _eqFrequencies,
            ["eqCenter"] = _eqCenter,
        };
        return Task.FromResult(JsonSerializer.Serialize(state));
    }
}
