namespace Hush.Protocol;

/// A hard opcode guard: the one place that decides whether the app may put a payload on the air.
/// Pure and portable, so it can be unit-tested with no Bluetooth and enforced the same way on
/// every platform.
public static class OpcodePolicy
{
    /// Frame data-type bytes (the tandem message type), not MDR command bytes.
    public const byte Ack = 0x01;
    public const byte Cmd1 = 0x0C;
    public const byte Cmd2 = 0x0E;

    /// Opcodes the app may emit unconditionally. Anything not here or cleared by <see cref="Permits"/>
    /// is refused before it reaches the air.
    public static readonly IReadOnlySet<byte> Allowed = new HashSet<byte>
    {
        0x00, 0x04, 0x12, 0x22, 0x50, 0x56, 0x58, 0x5A,
        0x66, 0x68, 0xA6, 0xE6, 0xE8, 0xF2, 0xF6, 0xFA,
    };

    /// Never emitted — on protocol v2 these are destructive or unverified:
    ///   0x98 SYSTEM_CONTROL_SET (reboot) · 0x24 POWER_SET (power off)
    ///   0x2D LARGE_DATA_COMMON (firmware) · 0xC4 JSON_GET
    public static readonly IReadOnlySet<byte> Forbidden = new HashSet<byte> { 0x98, 0x24, 0x2D, 0xC4 };

    /// SYSTEM_SET_PARAM (0xF8) and SYSTEM_SET_EXT_PARAM (0xFC) share an opcode space with a
    /// factory-reset command (RESET_SETTINGS = inquired type 0x09), so they are not blanket-allowed.
    /// They are let out ONLY for the speak-to-chat inquired types, so a factory reset can never be
    /// emitted however the rest of the app changes.
    public const byte SystemSetParam = 0xF8;
    public const byte SystemSetExtParam = 0xFC;
    public static readonly IReadOnlySet<byte> SmartTalkingTypes = new HashSet<byte> { 0x02, 0x0C };

    /// Whether the app may send this payload: the plain allow list plus the type-aware exception
    /// for the two SYSTEM write opcodes. A bare or wrong-typed 0xF8/0xFC, and the whole forbidden
    /// set, are refused.
    public static bool Permits(IReadOnlyList<byte> payload)
    {
        if (payload.Count == 0) return false;
        byte op = payload[0];
        if (Forbidden.Contains(op)) return false;
        if (op == SystemSetParam || op == SystemSetExtParam)
        {
            return payload.Count >= 2 && SmartTalkingTypes.Contains(payload[1]);
        }
        return Allowed.Contains(op);
    }
}
