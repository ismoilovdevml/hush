import Foundation
import IOBluetooth

/// Pick the headset to talk to.
///
/// Matching on the name alone is not enough: a paired "WH-700MAX" from another maker also
/// starts with "WH-", and with the Sony disconnected it would win by default. So the last
/// device that actually spoke the protocol is remembered and preferred, and a connected
/// device beats a merely paired one.
private let lastGoodAddressKey = "lastHeadsetAddress"

func rememberHeadset(address: String) {
    UserDefaults.standard.set(address, forKey: lastGoodAddressKey)
}

func findHeadset() -> (name: String, address: String)? {
    guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }

    // Sony's own model prefixes. WH-1000XM* is spelled out rather than left as "WH-" so that
    // another maker's WH-something does not match.
    let pattern = #"WH-1000XM|WF-|WI-|LinkBuds|ULT WEAR|WH-CH|WH-ULT"#
    let candidates = paired.filter {
        ($0.name ?? "").range(of: pattern, options: .regularExpression) != nil
    }

    let remembered = UserDefaults.standard.string(forKey: lastGoodAddressKey)
    let pick = candidates.first { $0.isConnected() && $0.addressString == remembered }
        ?? candidates.first { $0.isConnected() }
        ?? candidates.first { $0.addressString == remembered }
        ?? candidates.first

    guard let device = pick, let address = device.addressString else { return nil }
    return (device.name ?? "Headphones", address)
}
