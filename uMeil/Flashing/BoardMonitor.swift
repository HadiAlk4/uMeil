import Foundation
import IOKit
import IOKit.usb

/// The numbers a USB device identifies itself with.
struct USBDeviceID: Hashable, Sendable {
    var vendorID: Int
    var productID: Int
}

extension Board {
    /// The USB identity of the board's built-in debug probe.
    var debugProbe: USBDeviceID {
        switch self {
        // TI's In-Circuit Debug Interface (ICDI), the same on every Tiva LaunchPad.
        case .ekTM4C1294XL: USBDeviceID(vendorID: 0x1CBE, productID: 0x00FD)
        }
    }
}

/// Tells whether a board is plugged in.
///
/// This is only used to show the user what is connected. Flashing never
/// relies on it: OpenOCD is always asked, and its answer is the one that counts.
@MainActor
protocol BoardMonitoring: AnyObject {
    var isBoardConnected: Bool { get }
    /// Called on the main thread when a board is plugged in or unplugged.
    var onChange: ((Bool) -> Void)? { get set }
    func start()
}

/// Watches USB for a board's debug probe, using IOKit.
@MainActor
final class USBBoardMonitor: BoardMonitoring {
    let device: USBDeviceID
    var onChange: ((Bool) -> Void)?

    /// How many matching devices are plugged in right now.
    private var connectedCount = 0
    // Only touched on the main actor, and by `deinit` once nothing else can
    // reach them; `deinit` is not allowed to see them otherwise.
    private nonisolated(unsafe) var port: IONotificationPortRef?
    private nonisolated(unsafe) var iterators: [io_iterator_t] = []

    var isBoardConnected: Bool { connectedCount > 0 }

    init(device: USBDeviceID = Board.ekTM4C1294XL.debugProbe) {
        self.device = device
    }

    deinit {
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        if let port {
            IONotificationPortDestroy(port)
        }
    }

    /// What IOKit is asked to look for: USB devices with this vendor and product ID.
    nonisolated static func matchingDictionary(for device: USBDeviceID) -> [String: Any] {
        [
            kIOProviderClassKey: kIOUSBHostDeviceClassName,
            kUSBVendorID: device.vendorID,
            kUSBProductID: device.productID
        ]
    }

    /// Whether `device` is plugged in at this moment, without watching for changes.
    nonisolated static func isPresent(_ device: USBDeviceID) -> Bool {
        // The matching dictionary is consumed by the call.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDictionary(for: device) as CFDictionary)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// Starts watching. Devices that are already plugged in are counted
    /// before this returns.
    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)

        watch(kIOFirstMatchNotification, on: port) { context, iterator in
            USBBoardMonitor.monitor(from: context)?.devicesChanged(iterator, by: 1)
        }
        watch(kIOTerminatedNotification, on: port) { context, iterator in
            USBBoardMonitor.monitor(from: context)?.devicesChanged(iterator, by: -1)
        }
    }

    private func watch(_ notification: String, on port: IONotificationPortRef, callback: IOServiceMatchingCallback) {
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port,
            notification,
            Self.matchingDictionary(for: device) as CFDictionary,
            callback,
            Unmanaged.passUnretained(self).toOpaque(),
            &iterator
        )
        guard result == KERN_SUCCESS else { return }
        iterators.append(iterator)

        // The iterator starts out holding the devices that already match.
        // Going through it also arms the notification for later changes.
        devicesChanged(iterator, by: notification == kIOFirstMatchNotification ? 1 : 0)
    }

    /// Recovers the monitor a notification was registered for. Notifications
    /// are delivered on the main queue, which is where the monitor lives.
    private nonisolated static func monitor(from context: UnsafeMutableRawPointer?) -> MainActorMonitor? {
        guard let context else { return nil }
        return MainActorMonitor(monitor: Unmanaged<USBBoardMonitor>.fromOpaque(context).takeUnretainedValue())
    }

    /// Empties `iterator`, adding `change` to the count for each device in it.
    fileprivate func devicesChanged(_ iterator: io_iterator_t, by change: Int) {
        let wasConnected = isBoardConnected
        while case let device = IOIteratorNext(iterator), device != 0 {
            IOObjectRelease(device)
            connectedCount = max(connectedCount + change, 0)
        }
        if isBoardConnected != wasConnected {
            onChange?(isBoardConnected)
        }
    }
}

/// Carries a monitor from IOKit's C callback back onto the main actor.
private struct MainActorMonitor {
    let monitor: USBBoardMonitor

    nonisolated func devicesChanged(_ iterator: io_iterator_t, by change: Int) {
        MainActor.assumeIsolated {
            monitor.devicesChanged(iterator, by: change)
        }
    }
}
