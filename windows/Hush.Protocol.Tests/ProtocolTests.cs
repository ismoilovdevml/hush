using Hush.Protocol;
using Xunit;

namespace Hush.Protocol.Tests;

// Tests for the wire format and the payload encodings. No headphones involved. These mirror the
// macOS test suite so the two implementations stay byte-for-byte identical.
public class FrameCodecTests
{
    [Fact]
    public void PlainPayloadRoundTrips()
    {
        var payload = new byte[] { 0x22, 0x00 };
        var wire = SonyFrameCodec.Encode(0x0C, 0, payload);
        var frames = SonyFrameCodec.Decode(new List<byte>(wire));
        Assert.Single(frames);
        Assert.Equal(payload, frames[0].Payload);
    }

    [Fact]
    public void BufferIsFullyConsumed()
    {
        var buffer = new List<byte>(SonyFrameCodec.Encode(0x0C, 0, new byte[] { 0x22, 0x00 }));
        SonyFrameCodec.Decode(buffer);
        Assert.Empty(buffer);
    }

    [Fact]
    public void MarkerBytesAreEscapedWithBit4Cleared()
    {
        // 0x3E, 0x3D, 0x3C must be escaped as 0x3D then the byte with bit 4 cleared.
        var payload = new byte[] { 0x5B, 0x3E, 0x3D, 0x3C, 0x80 };
        var wire = SonyFrameCodec.Encode(0x0C, 1, payload);
        string hex = string.Join(" ", wire.Select(b => b.ToString("x2")));
        Assert.Contains("3d 2e", hex); // 0x3E
        Assert.Contains("3d 2d", hex); // 0x3D
        Assert.Contains("3d 2c", hex); // 0x3C
        var frames = SonyFrameCodec.Decode(new List<byte>(wire));
        Assert.Single(frames);
        Assert.Equal(payload, frames[0].Payload);
    }

    [Fact]
    public void AChecksumOf0x3EIsEscaped()
    {
        // dataType 0x0C, seq 0, payload [0x31] sums to 0x3E (the start marker).
        var wire = SonyFrameCodec.Encode(0x0C, 0, new byte[] { 0x31 });
        string hex = string.Join(" ", wire.Select(b => b.ToString("x2")));
        Assert.EndsWith("3d 2e 3c", hex);
        var frames = SonyFrameCodec.Decode(new List<byte>(wire));
        Assert.Single(frames);
        Assert.Equal(new byte[] { 0x31 }, frames[0].Payload);
    }

    [Fact]
    public void ABadChecksumIsDropped()
    {
        var wire = new List<byte>(SonyFrameCodec.Encode(0x0C, 0, new byte[] { 0x22, 0x00 }));
        wire[wire.Count - 2] ^= 0xFF; // corrupt a byte before the end marker
        Assert.Empty(SonyFrameCodec.Decode(wire));
    }
}

public class CommandTests
{
    [Fact]
    public void AmbientSetLayoutAndLevelClamp()
    {
        var p = SonyCommand.AmbientSet(0x17, SonyCommand.AmbientMode.Ambient, focusOnVoice: true, level: 99);
        Assert.Equal(new byte[] { 0x68, 0x17, 0x01, 1, 1, 1, 20 }, p); // level clamped to 20
    }

    [Fact]
    public void AmbientParseRejectsUnrelatedOpcode()
    {
        Assert.Null(SonyCommand.ParseAmbient(new byte[] { 0x57, 0x00, 0x00, 0x0a }));
    }

    [Fact]
    public void EqualizerManualBandsClampAndOffset()
    {
        var p = SonyCommand.EqualizerBandsSet(0x00, new[] { -99, 0, 99 }, center: 6);
        Assert.Equal(new byte[] { 0x58, 0x00, 0xA0, 3, 0, 6, 12 }, p);
    }

    [Fact]
    public void EqualizerParseIsBoundsSafe()
    {
        // declared count larger than the payload must not throw, just return null
        Assert.Null(SonyCommand.ParseEqualizer(new byte[] { 0x57, 0x00, 0xA0, 10, 6, 6 }));
        var ok = SonyCommand.ParseEqualizer(new byte[] { 0x57, 0x00, 0xA0, 2, 6, 7 }, center: 6);
        Assert.NotNull(ok);
        Assert.Equal(new[] { 0, 1 }, ok!.Value.Bands);
    }
}

public class SpeakToChatAndAdaptiveTests
{
    [Fact]
    public void SmartTalkingEnableIsInverted()
    {
        Assert.Equal(new byte[] { 0xF8, 0x02, 0x00, 0x00 }, SonyCommand.SmartTalkingSet(0x02, enabled: true));
        Assert.Equal(new byte[] { 0xF8, 0x02, 0x01, 0x01 }, SonyCommand.SmartTalkingSet(0x02, enabled: false));
    }

    [Fact]
    public void SmartTalkingConfigTypeDifference()
    {
        // TYPE1 carries the voice-focus byte; TYPE2 does not.
        Assert.Equal(new byte[] { 0xFC, 0x02, 0x01, 0x00, 0x02 },
            SonyCommand.SmartTalkingConfigSet(0x02, SonyCommand.DetectSensitivity.High,
                SonyCommand.ModeOutTime.Slow, voiceFocus: true));
        Assert.Equal(new byte[] { 0xFC, 0x0C, 0x02, 0x03 },
            SonyCommand.SmartTalkingConfigSet(0x0C, SonyCommand.DetectSensitivity.Low,
                SonyCommand.ModeOutTime.KeepUntilStopped));
    }

    [Fact]
    public void SmartTalkingReplyParsesInverted()
    {
        Assert.True(SonyCommand.ParseSmartTalking(new byte[] { 0xF7, 0x02, 0x00, 0x00 })!.Value.Enabled);
        Assert.False(SonyCommand.ParseSmartTalking(new byte[] { 0xF7, 0x02, 0x01, 0x01 })!.Value.Enabled);
    }

    [Fact]
    public void AdaptiveAncIsNineBytes()
    {
        var p = SonyCommand.AmbientSetAdaptive(SonyCommand.AmbientMode.NoiseCancelling,
            focusOnVoice: false, level: 10, adaptiveOn: true, SonyCommand.NoiseAdaptiveSensitivity.Standard);
        Assert.Equal(new byte[] { 0x68, 0x19, 0x01, 1, 0, 0, 10, 1, 0 }, p);
    }
}

public class OpcodePolicyTests
{
    [Theory]
    [InlineData(0x98)]
    [InlineData(0x24)]
    [InlineData(0x2D)]
    [InlineData(0xC4)]
    public void DestructiveOpcodesAreRefused(byte op)
    {
        Assert.Contains(op, OpcodePolicy.Forbidden);
        Assert.DoesNotContain(op, OpcodePolicy.Allowed);
        Assert.False(OpcodePolicy.Permits(new byte[] { op }));
    }

    [Fact]
    public void SystemWritesAreTypeGated()
    {
        Assert.DoesNotContain((byte)0xF8, OpcodePolicy.Allowed);
        Assert.DoesNotContain((byte)0xFC, OpcodePolicy.Allowed);
        Assert.False(OpcodePolicy.Permits(new byte[] { 0xF8 }));            // bare
        Assert.False(OpcodePolicy.Permits(new byte[] { 0xF8, 0x09 }));      // RESET_SETTINGS
        Assert.False(OpcodePolicy.Permits(new byte[] { 0xFC, 0x09 }));
        Assert.True(OpcodePolicy.Permits(new byte[] { 0xF8, 0x02 }));       // speak-to-chat
        Assert.True(OpcodePolicy.Permits(new byte[] { 0xFC, 0x0C }));
        Assert.DoesNotContain((byte)0x09, OpcodePolicy.SmartTalkingTypes);
    }

    [Fact]
    public void OrdinaryWritesPass()
    {
        Assert.True(OpcodePolicy.Permits(new byte[] { 0x68, 0x19 }));       // ANC set
        Assert.True(OpcodePolicy.Permits(new byte[] { 0x58, 0x00, 0xA0, 0x0A })); // EQ set
        Assert.True(OpcodePolicy.Permits(new byte[] { 0x22, 0x00 }));       // battery get
    }
}
