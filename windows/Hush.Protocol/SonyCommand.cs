namespace Hush.Protocol;

/// Payload construction and parsing for the MDR v2 protocol, kept free of Bluetooth so it can be
/// tested directly. Pure and portable — the same logic the proven macOS build uses.
public static class SonyCommand
{
    public enum AmbientMode { Off, NoiseCancelling, Ambient }

    // ---- ambient sound control (ANC) -------------------------------------------------------
    //
    // The inquiry type is a parameter, discovered rather than assumed: the WH-1000XM6 answers on
    // 0x19, other models may use 0x15 / 0x17. 0x19 is tried first.
    public static readonly byte[] AmbientTypes = { 0x19, 0x17, 0x15, 0x22 };

    public static byte[] AmbientGet(byte type) => new byte[] { 0x66, type };

    public static byte[] AmbientSet(byte type, AmbientMode mode, bool focusOnVoice, int level) => new byte[]
    {
        0x68, type, 0x01,
        (byte)(mode == AmbientMode.Off ? 0 : 1),
        (byte)(mode == AmbientMode.Ambient ? 1 : 0),
        (byte)(focusOnVoice ? 1 : 0),
        (byte)Math.Clamp(level, 0, 20),
    };

    /// Parses a 0x67 reply or a 0x69 notification.
    /// Layout: [opcode, type, 0x01, on, ambientFlag, focusOnVoice, level, 0x00, 0x00]
    public static (AmbientMode Mode, bool FocusOnVoice, int Level)? ParseAmbient(IReadOnlyList<byte> p)
    {
        if (p.Count < 7 || (p[0] != 0x67 && p[0] != 0x69)) return null;
        var mode = p[3] == 0 ? AmbientMode.Off : (p[4] == 1 ? AmbientMode.Ambient : AmbientMode.NoiseCancelling);
        return (mode, p[5] == 1, Math.Min(p[6], (byte)20));
    }

    // ---- equalizer -------------------------------------------------------------------------
    //
    // The headphones describe their own equalizer: 0x50 reports band count and level steps,
    // 0x5A reports the centre frequencies. On the XM6 that is 10 bands and 13 steps, so the centre
    // is 6 and a band travels the wire as dB + 6, range -6..+6. A flat curve reads back as ten 0x06.
    public static readonly byte[] EqualizerTypes = { 0x00, 0x02, 0x04, 0x03 };
    public const byte ManualPreset = 0xA0;

    public static int Center(byte levelSteps) => (levelSteps - 1) / 2;

    public static byte[] EqualizerGet(byte type) => new byte[] { 0x56, type };
    public static byte[] EqualizerCapabilityGet(byte type) => new byte[] { 0x50, type, 0x01 };
    public static byte[] EqualizerBandsGet(byte type) => new byte[] { 0x5A, type };
    public static byte[] EqualizerPresetSet(byte type, byte preset) => new byte[] { 0x58, type, preset, 0x00 };

    public static byte[] EqualizerBandsSet(byte type, IReadOnlyList<int> bands, int center = 6)
    {
        var o = new List<byte> { 0x58, type, ManualPreset, (byte)bands.Count };
        foreach (var b in bands) o.Add((byte)(Math.Clamp(b, -center, center) + center));
        return o.ToArray();
    }

    /// Parses a 0x57 reply or 0x59 notification: [opcode, type, preset, count, values...]
    public static (byte Preset, int[] Bands)? ParseEqualizer(IReadOnlyList<byte> p, int center = 6)
    {
        if (p.Count < 4 || (p[0] != 0x57 && p[0] != 0x59)) return null;
        int count = p[3];
        if (p.Count < 4 + count) return null;
        var bands = new int[count];
        for (int i = 0; i < count; i++) bands[i] = p[4 + i] - center;
        return (p[2], bands);
    }

    /// Parses the 0x51 capability reply: [0x51, ?, bandCount, levelSteps, presetCount, ...]
    public static (int BandCount, byte LevelSteps, byte[] Presets)? ParseEqualizerCapability(IReadOnlyList<byte> p)
    {
        if (p.Count < 5 || p[0] != 0x51) return null;
        var presets = new List<byte>();
        int offset = 5;
        for (int k = 0; k < p[4]; k++)
        {
            if (offset + 1 >= p.Count) return null;
            presets.Add(p[offset]);
            offset += 2 + p[offset + 1];
        }
        return (p[2], p[3], presets.ToArray());
    }

    /// Parses the 0x5B band table: [0x5B, type, count, (unit, hi, lo) * count]
    public static int[]? ParseEqualizerFrequencies(IReadOnlyList<byte> p)
    {
        if (p.Count < 3 || p[0] != 0x5B) return null;
        int count = p[2];
        if (p.Count < 3 + count * 3) return null;
        var hz = new int[count];
        for (int i = 0; i < count; i++)
        {
            int b = 3 + i * 3;
            hz[i] = p[b + 1] << 8 | p[b + 2];
        }
        return hz;
    }

    public static string FrequencyLabel(int hz) => hz >= 1000 ? $"{hz / 1000}k" : $"{hz}";

    // ---- speak-to-chat (Smart Talking Mode) ------------------------------------------------
    //
    // Two commands: the basic SYSTEM param (get 0xF6 / set 0xF8) carries enable/disable, the
    // extended SYSTEM param (get 0xFA / set 0xFC) carries sensitivity + mode-out-time. The inquired
    // type is 0x02 (TYPE1) or 0x0C (TYPE2, newer); the device's capability says which. On/off is
    // INVERTED on the wire — enabling writes 0x00.
    public const byte SmartTalkingTypeV1 = 0x02;
    public const byte SmartTalkingTypeV2 = 0x0C;

    public enum DetectSensitivity : byte { Auto = 0, High = 1, Low = 2 }
    public enum ModeOutTime : byte { Fast = 0, Mid = 1, Slow = 2, KeepUntilStopped = 3 }

    public static byte[] SmartTalkingGet(byte type) => new byte[] { 0xF6, type };
    public static byte[] SmartTalkingConfigGet(byte type) => new byte[] { 0xFA, type };

    /// Enable/disable. 0x00 = enabled on the wire (the on/off value is inverted). byte[3] is the
    /// "preview" flag, sent equal to the main value.
    public static byte[] SmartTalkingSet(byte type, bool enabled)
    {
        byte v = (byte)(enabled ? 0x00 : 0x01);
        return new byte[] { 0xF8, type, v, v };
    }

    /// Sensitivity + mode-out-time. TYPE1 (0x02) carries an extra voice-focus byte (also inverted);
    /// TYPE2 (0x0C) does not.
    public static byte[] SmartTalkingConfigSet(byte type, DetectSensitivity sensitivity,
                                               ModeOutTime modeOutTime, bool voiceFocus = false)
    {
        if (type == SmartTalkingTypeV2)
        {
            return new byte[] { 0xFC, type, (byte)sensitivity, (byte)modeOutTime };
        }
        return new byte[] { 0xFC, type, (byte)sensitivity, (byte)(voiceFocus ? 0x00 : 0x01), (byte)modeOutTime };
    }

    /// Parses a 0xF7 basic reply: [0xF7, type, value, preview]; value 0x00 = enabled (inverted).
    public static (bool Enabled, byte Type)? ParseSmartTalking(IReadOnlyList<byte> p)
    {
        if (p.Count < 3 || p[0] != 0xF7) return null;
        return (p[2] == 0x00, p[1]);
    }

    // ---- noise-adaptive ANC (inquiry type 0x19) --------------------------------------------
    //
    // Inquiry type 0x19 is a 9-byte frame: the 7-byte core shared with type 0x17, plus
    // noise-adaptive on/off and sensitivity.
    public enum NoiseAdaptiveSensitivity : byte { Standard = 0, High = 1, Low = 2 }

    public static byte[] AmbientSetAdaptive(AmbientMode mode, bool focusOnVoice, int level,
                                            bool adaptiveOn, NoiseAdaptiveSensitivity sensitivity) => new byte[]
    {
        0x68, 0x19, 0x01,
        (byte)(mode == AmbientMode.Off ? 0 : 1),
        (byte)(mode == AmbientMode.Ambient ? 1 : 0),
        (byte)(focusOnVoice ? 1 : 0),
        (byte)Math.Clamp(level, 0, 20),
        (byte)(adaptiveOn ? 1 : 0),
        (byte)sensitivity,
    };
}
