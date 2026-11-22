import Foundation
import IOKit
import IOKit.usb
import os

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
    func stop()
}

extension BoardMonitoring {
    func stop() {}
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
    private nonisolated(unsafe) var callbackToken: UInt?

    private nonisolated static let activeMonitors = OSAllocatedUnfairLock(initialState: [UInt: CallbackBox]())
    private nonisolated static let nextToken = OSAllocatedUnfairLock(initialState: UInt(1))

    var isBoardConnected: Bool { connectedCount > 0 }
    var isRunning: Bool { port != nil && callbackToken != nil }

    init(device: USBDeviceID = Board.ekTM4C1294XL.debugProbe) {
        self.device = device
    }

    deinit {
        if let token = callbackToken {
            Self.activeMonitors.withLock { $0.removeValue(forKey: token) }
        }
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

        let token = Self.nextToken.withLock { next in
            let current = next
            next = next &+ 1
            if next == 0 { next = 1 }
            return current
        }
        callbackToken = token
        let box = CallbackBox(self)
        Self.activeMonitors.withLock { $0[token] = box }

        let context = UnsafeMutableRawPointer(bitPattern: token)
        watch(kIOFirstMatchNotification, on: port, context: context) { context, iterator in
            USBBoardMonitor.monitor(from: context)?.devicesChanged(iterator, by: 1)
        }
        watch(kIOTerminatedNotification, on: port, context: context) { context, iterator in
            USBBoardMonitor.monitor(from: context)?.devicesChanged(iterator, by: -1)
        }
    }

    /// Stops watching and releases all IOKit resources. Safe to call multiple times.
    func stop() {
        if let token = callbackToken {
            Self.activeMonitors.withLock { $0.removeValue(forKey: token) }
            callbackToken = nil
        }
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        iterators.removeAll()
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
        connectedCount = 0
    }

    private func watch(
        _ notification: String,
        on port: IONotificationPortRef,
        context: UnsafeMutableRawPointer?,
        callback: IOServiceMatchingCallback
    ) {
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port,
            notification,
            Self.matchingDictionary(for: device) as CFDictionary,
            callback,
            context,
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
        let token = UInt(bitPattern: context)
        guard let box = activeMonitors.withLock({ $0[token] }) else { return nil }
        return MainActorMonitor(box: box)
    }

    /// Exposes the opaque token pointer for tests verifying post-teardown callback safety.
    var callbackContextForTesting: UnsafeMutableRawPointer? {
        callbackToken.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    }

    /// Invokes the callback resolution path for tests verifying post-stop / post-deinit safety.
    nonisolated static func dispatchNotificationForTesting(
        context: UnsafeMutableRawPointer?,
        iterator: io_iterator_t = 0,
        change: Int = 1
    ) {
        monitor(from: context)?.devicesChanged(iterator, by: change)
    }

    /// Empties `iterator`, adding `change` to the count for each device in it.
    fileprivate func devicesChanged(_ iterator: io_iterator_t, by change: Int) {
        guard iterator != 0 else { return }
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

private final class CallbackBox: @unchecked Sendable {
    weak var monitor: USBBoardMonitor?

    init(_ monitor: USBBoardMonitor) {
        self.monitor = monitor
    }
}

/// Carries a monitor from IOKit's C callback back onto the main actor.
private struct MainActorMonitor {
    let box: CallbackBox

    nonisolated func devicesChanged(_ iterator: io_iterator_t, by change: Int) {
        MainActor.assumeIsolated {
            box.monitor?.devicesChanged(iterator, by: change)
        }
    }
}
