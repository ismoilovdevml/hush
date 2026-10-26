using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Devices.Enumeration;
using Windows.Networking.Sockets;
using Windows.Storage.Streams;
using Hush.Protocol;

namespace Hush.Bluetooth;

// One long-lived RFCOMM channel to a Sony MDR v2 headset, over WinRT. Mirrors the macOS SonyLink:
// framing via SonyFrameCodec, the hard opcode guard via OpcodePolicy, strict request/response with
// auto-ACK, one exchange in flight.
//
// WINDOWS-ONLY and NOT YET VERIFIED ON A LIVE HEADSET. It compiles and runs on Windows 10 2004+,
// not on macOS; the Bluetooth connect/exchange path must be tested on real Windows (or a VM with a
// USB Bluetooth dongle passed through).
public sealed class SonyLink : IDisposable
{
    /// The SPP service UUID the headset advertises (maps to RFCOMM channel 9 via its SDP record).
    public static readonly Guid SppUuid = Guid.Parse("956c7b26-d49a-4ba8-b03f-b17d393cb6e2");

    private StreamSocket? _socket;
    private DataWriter? _writer;
    private DataReader? _reader;
    private readonly List<byte> _rx = new();
    private readonly Queue<SonyFrame> _pending = new();
    private byte _txSeq;
    private readonly SemaphoreSlim _io = new(1, 1); // one request/response exchange at a time

    public bool IsConnected => _socket != null;

    /// Find a paired headset advertising the Sony SPP service, preferring one whose name matches.
    public static async Task<string?> FindDeviceIdAsync(string? nameContains = "WH-1000XM6")
    {
        string selector = RfcommDeviceService.GetDeviceSelector(RfcommServiceId.FromUuid(SppUuid));
        var found = await DeviceInformation.FindAllAsync(selector);
        foreach (var d in found)
        {
            if (nameContains == null || d.Name.Contains(nameContains, StringComparison.OrdinalIgnoreCase))
                return d.Id;
        }
        return found.Count > 0 ? found[0].Id : null;
    }

    public async Task<bool> ConnectAsync(string deviceId)
    {
        var service = await RfcommDeviceService.FromIdAsync(deviceId);
        if (service == null) return false;

        _socket = new StreamSocket();
        await _socket.ConnectAsync(service.ConnectionHostName, service.ConnectionServiceName,
            SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication);

        _writer = new DataWriter(_socket.OutputStream);
        _reader = new DataReader(_socket.InputStream) { InputStreamOptions = InputStreamOptions.Partial };
        _rx.Clear();
        _pending.Clear();
        _txSeq = 0;
        return true;
    }

    /// Send one framed request and return the first reply whose opcode == <paramref name="expect"/>,
    /// or null on timeout. Refused (null) before anything is sent if the payload is not permitted by
    /// the opcode policy. Every frame the device sends is acknowledged; the sequence bit flips per
    /// completed exchange.
    public async Task<byte[]?> RequestAsync(byte dataType, byte[] payload, byte expect, TimeSpan? timeout = null)
    {
        if (payload.Length == 0 || !OpcodePolicy.Permits(payload)) return null;
        if (_socket == null || _writer == null || _reader == null) return null;

        var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.FromSeconds(2.5));
        await _io.WaitAsync();
        try
        {
            await WriteFrameAsync(dataType, _txSeq, payload);

            while (DateTime.UtcNow < deadline)
            {
                var next = await NextFrameAsync(deadline);
                if (next is not { } frame) break;

                if (frame.DataType == OpcodePolicy.Ack) continue; // our write was acknowledged

                // Acknowledge whatever the device sent, or it retransmits.
                await WriteFrameAsync(OpcodePolicy.Ack, (byte)(1 - frame.Seq), Array.Empty<byte>());

                if (frame.Opcode == expect)
                {
                    _txSeq ^= 1;
                    return frame.Payload;
                }
            }
            return null;
        }
        finally
        {
            _io.Release();
        }
    }

    private async Task WriteFrameAsync(byte dataType, byte seq, byte[] payload)
    {
        _writer!.WriteBytes(SonyFrameCodec.Encode(dataType, seq, payload));
        await _writer.StoreAsync();
    }

    private async Task<SonyFrame?> NextFrameAsync(DateTime deadline)
    {
        if (_pending.Count > 0) return _pending.Dequeue();

        while (DateTime.UtcNow < deadline)
        {
            var remaining = deadline - DateTime.UtcNow;
            if (remaining <= TimeSpan.Zero) return null;

            using var cts = new CancellationTokenSource(remaining);
            uint n;
            try { n = await _reader!.LoadAsync(512).AsTask(cts.Token); }
            catch (OperationCanceledException) { return null; }

            if (n == 0) return null; // channel closed
            var chunk = new byte[n];
            _reader!.ReadBytes(chunk);
            _rx.AddRange(chunk);

            foreach (var frame in SonyFrameCodec.Decode(_rx)) _pending.Enqueue(frame);
            if (_pending.Count > 0) return _pending.Dequeue();
        }
        return null;
    }

    public void Dispose()
    {
        _writer?.Dispose();
        _reader?.Dispose();
        _socket?.Dispose();
        _writer = null;
        _reader = null;
        _socket = null;
    }
}
