namespace Hush.Protocol;

/// A single decoded MDR frame.
public readonly record struct SonyFrame(byte DataType, byte Seq, byte[] Payload)
{
    public byte Opcode => Payload.Length > 0 ? Payload[0] : (byte)0xFF;
}

/// The MDR wire format, on its own so it can be tested without a headset.
///
/// Frame: 0x3E | dataType | seq | length (4B BE) | payload | checksum | 0x3C
/// checksum = sum(dataType ... payload) &amp; 0xFF.
/// 0x3E / 0x3D / 0x3C inside the frame are escaped as 0x3D then (b &amp; 0xEF) — bit 4 cleared;
/// the reader restores them with (b | 0x10). Pure and portable.
public static class SonyFrameCodec
{
    public const byte Start = 0x3E;
    public const byte End = 0x3C;
    public const byte Esc = 0x3D;
    public const byte EscapeBit = 0x10;

    public static byte Checksum(IReadOnlyList<byte> body)
    {
        int sum = 0;
        for (int i = 0; i < body.Count; i++) sum += body[i];
        return (byte)(sum & 0xFF);
    }

    public static byte[] Encode(byte dataType, byte seq, IReadOnlyList<byte> payload)
    {
        uint n = (uint)payload.Count;
        var body = new List<byte>
        {
            dataType, seq,
            (byte)((n >> 24) & 0xFF), (byte)((n >> 16) & 0xFF), (byte)((n >> 8) & 0xFF), (byte)(n & 0xFF),
        };
        body.AddRange(payload);
        body.Add(Checksum(body));

        var output = new List<byte> { Start };
        foreach (var b in body)
        {
            if (b == Start || b == End || b == Esc)
            {
                output.Add(Esc);
                output.Add((byte)(b & ~EscapeBit));
            }
            else
            {
                output.Add(b);
            }
        }
        output.Add(End);
        return output.ToArray();
    }

    /// Pulls every complete frame out of <paramref name="buffer"/>, consuming what it reads and
    /// leaving any partial tail behind. Frames that fail their checksum or whose declared length
    /// does not match are dropped rather than passed on.
    public static List<SonyFrame> Decode(List<byte> buffer)
    {
        var frames = new List<SonyFrame>();

        int start;
        while ((start = buffer.IndexOf(Start)) >= 0)
        {
            var body = new List<byte>();
            int i = start + 1;
            bool sawEnd = false;

            while (i < buffer.Count)
            {
                if (buffer[i] == End) { sawEnd = true; break; }
                if (buffer[i] == Esc)
                {
                    i++;
                    if (i < buffer.Count) body.Add((byte)(buffer[i] | EscapeBit));
                }
                else
                {
                    body.Add(buffer[i]);
                }
                i++;
            }

            if (!sawEnd)
            {
                // keep the partial frame, drop whatever preceded it
                if (start > 0) buffer.RemoveRange(0, start);
                return frames;
            }
            buffer.RemoveRange(0, i + 1);

            if (body.Count < 7) continue;
            if (Checksum(body.GetRange(0, body.Count - 1)) != body[^1]) continue;

            int length = body[2] << 24 | body[3] << 16 | body[4] << 8 | body[5];
            if (length != body.Count - 7) continue;

            frames.Add(new SonyFrame(body[0], body[1], body.GetRange(6, length).ToArray()));
        }
        return frames;
    }
}
