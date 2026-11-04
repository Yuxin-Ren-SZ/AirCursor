import AppKit
import IOBluetooth

struct HeadphoneDevice: Identifiable, Equatable, Hashable {
    /// Bluetooth address, e.g. "a1-b2-c3-d4-e5-f6".
    let id: String
    let name: String
    let isConnected: Bool
    let isPaired: Bool

    /// Head tracking needs AirPods Pro, AirPods Max, AirPods (3rd gen or later) or Beats Fit Pro.
    var likelySupportsMotion: Bool {
        let n = name.lowercased()
        if n.contains("airpods pro") || n.contains("airpods max") || n.contains("fit pro") { return true }
        if n.contains("airpods") { return !n.contains("2nd") && !n.contains("1st") }
        return false
    }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("max") { return "airpodsmax" }
        if n.contains("pro") { return "airpodspro" }
        if n.contains("beats") { return "beats.headphones" }
        return n.contains("airpods") ? "airpods" : "headphones"
    }
}

enum BluetoothDeviceFilter {
    static let audioMajorClass: UInt32 = 0x04

    static func isHeadphoneLike(_ device: IOBluetoothDevice) -> Bool {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods") || name.contains("beats") { return true }
        return device.deviceClassMajor == audioMajorClass
    }

    static func model(_ device: IOBluetoothDevice) -> HeadphoneDevice {
        HeadphoneDevice(
            id: device.addressString ?? UUID().uuidString,
            name: device.name ?? "Unknown device",
            isConnected: device.isConnected(),
            isPaired: device.isPaired()
        )
    }
}

/// Lists and connects already-paired headphones.
final class BluetoothService {
    func pairedHeadphones() -> [HeadphoneDevice] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return devices
            .filter(BluetoothDeviceFilter.isHeadphoneLike)
            .map(BluetoothDeviceFilter.model)
            .sorted { lhs, rhs in
                if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
                if lhs.likelySupportsMotion != rhs.likelySupportsMotion { return lhs.likelySupportsMotion }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Opens a baseband connection. Blocking in IOBluetooth, so run off the main thread.
    func connect(address: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let device = IOBluetoothDevice(addressString: address) else { return false }
            if device.isConnected() { return true }
            return device.openConnection() == kIOReturnSuccess
        }.value
    }

    func disconnect(address: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let device = IOBluetoothDevice(addressString: address) else { return false }
            guard device.isConnected() else { return true }
            return device.closeConnection() == kIOReturnSuccess
        }.value
    }

    static func openSystemBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }
}
