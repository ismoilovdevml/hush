import Foundation
import IOBluetooth

/// Pick a paired Sony headset. Prefer one that is currently connected.
func findHeadset() -> (name: String, address: String)? {
    guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
    let sony = paired.filter { ($0.name ?? "").range(of: #"WH-|WF-|WI-|LinkBuds|ULT"#, options: .regularExpression) != nil }
    let pick = sony.first(where: { $0.isConnected() }) ?? sony.first
    guard let d = pick, let addr = d.addressString else { return nil }
    return (d.name ?? "Headphones", addr)
}
