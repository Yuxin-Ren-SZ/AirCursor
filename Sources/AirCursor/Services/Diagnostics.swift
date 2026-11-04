import CoreMotion
import os

enum Diagnostics {
    /// View with: log stream --level info --predicate 'subsystem == "io.github.m-afham.AirCursor"'
    static let log = Logger(subsystem: "io.github.m-afham.AirCursor", category: "app")
}

extension CMAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: "not asked yet"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "allowed"
        @unknown default: "unknown"
        }
    }
}
