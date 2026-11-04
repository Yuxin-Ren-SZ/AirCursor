import Foundation
import IOBluetooth

/// Discovers headphones in pairing mode and pairs them (Secure Simple Pairing, "just works").
@MainActor
final class PairingService: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case pairing(name: String)
        case paired(name: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var discovered: [HeadphoneDevice] = []

    /// Called after a device pairs and connects; argument is its address.
    var onPaired: ((String) -> Void)?

    private var inquiry: IOBluetoothDeviceInquiry?
    private var pairer: IOBluetoothDevicePair?
    private var pairingDevice: IOBluetoothDevice?
    private var found: [String: IOBluetoothDevice] = [:]

    var isSearching: Bool { state == .searching }

    func startSearch() {
        stopSearch()
        found.removeAll()
        discovered.removeAll()
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else {
            state = .failed("Bluetooth is unavailable.")
            return
        }
        inquiry.updateNewDeviceNames = true
        inquiry.inquiryLength = 15
        let result = inquiry.start()
        guard result == kIOReturnSuccess else {
            state = .failed("Couldn't start searching. Make sure Bluetooth is on. (\(result))")
            return
        }
        self.inquiry = inquiry
        state = .searching
    }

    func stopSearch() {
        inquiry?.stop()
        inquiry = nil
        if state == .searching { state = .idle }
    }

    func pair(_ id: String) {
        guard let device = found[id] else { return }
        stopSearch()
        let name = device.name ?? "device"
        guard let pairer = IOBluetoothDevicePair(device: device) else {
            state = .failed("Couldn't pair with \(name).")
            return
        }
        pairer.delegate = self
        self.pairer = pairer
        pairingDevice = device
        state = .pairing(name: name)
        let result = pairer.start()
        if result != kIOReturnSuccess {
            state = .failed("Couldn't pair with \(name). (\(result))")
            self.pairer = nil
        }
    }

    private func upsert(_ device: IOBluetoothDevice) {
        guard BluetoothDeviceFilter.isHeadphoneLike(device), let address = device.addressString else { return }
        found[address] = device
        let model = BluetoothDeviceFilter.model(device)
        if let i = discovered.firstIndex(where: { $0.id == address }) {
            discovered[i] = model
        } else {
            discovered.append(model)
        }
    }

    private func finishPairing(error: IOReturn) {
        let device = pairingDevice
        let name = device?.name ?? "device"
        pairer = nil
        pairingDevice = nil
        guard error == kIOReturnSuccess, let device, let address = device.addressString else {
            state = .failed("Pairing with \(name) failed (\(error)). Put the case in pairing mode and try again.")
            return
        }
        Task.detached { _ = device.openConnection() }
        state = .paired(name: name)
        onPaired?(address)
    }
}

extension PairingService: IOBluetoothDeviceInquiryDelegate {
    nonisolated func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        guard let device else { return }
        MainActor.assumeIsolated { upsert(device) }
    }

    nonisolated func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        guard let device else { return }
        MainActor.assumeIsolated { upsert(device) }
    }

    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        MainActor.assumeIsolated {
            guard state == .searching else { return }
            inquiry = nil
            state = .idle
        }
    }
}

extension PairingService: IOBluetoothDevicePairDelegate {
    nonisolated func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    nonisolated func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        MainActor.assumeIsolated { finishPairing(error: error) }
    }
}
