import Foundation
import IOKit
import IOKit.serial

/// A serial port the Mac knows about.
struct SerialPortInfo: Equatable, Sendable {
    /// The device to open, for example `/dev/cu.usbmodem0F0130B71`.
    var path: String
    /// The USB device behind the port, or `nil` for ports that are not USB.
    var usbDevice: USBDeviceID?

    /// The device name without `/dev/cu.`, for example `usbmodem0F0130B71`.
    var name: String {
        let file = URL(filePath: path).lastPathComponent
        return file.hasPrefix("cu.") ? String(file.dropFirst(3)) : file
    }

    /// The board whose virtual COM port this is, if it is one uMeil knows.
    /// The COM port is part of the same USB device as the debug probe.
    var board: Board? {
        Board.allCases.first { $0.debugProbe == usbDevice }
    }

    /// What the port is called in the port menu.
    var displayName: String {
        if let board {
            return "\(board.displayName) (\(name))"
        }
        return name
    }
}

/// Finds serial ports, using IOKit.
enum SerialPortList {
    /// The ports present right now, with a board's port first.
    static func current() -> [SerialPortInfo] {
        var iterator: io_iterator_t = 0
        // The matching dictionary is consumed by the call.
        let matching = IOServiceMatching(kIOSerialBSDServiceValue)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var ports: [SerialPortInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(kIOCalloutDeviceKey, of: service) as? String else { continue }

            var device: USBDeviceID?
            if let vendor = property("idVendor", of: service, searchingParents: true) as? Int,
               let product = property("idProduct", of: service, searchingParents: true) as? Int {
                device = USBDeviceID(vendorID: vendor, productID: product)
            }
            ports.append(SerialPortInfo(path: path, usbDevice: device))
        }
        return sorted(ports)
    }

    /// Boards first, then other USB ports, then the rest; by name within each group.
    static func sorted(_ ports: [SerialPortInfo]) -> [SerialPortInfo] {
        func rank(_ port: SerialPortInfo) -> Int {
            if port.board != nil { return 0 }
            return port.usbDevice != nil ? 1 : 2
        }
        return ports.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }

    /// The port to select when the list is shown: the one chosen last time
    /// if it is still there, otherwise a board's, otherwise the first.
    static func preferred(in ports: [SerialPortInfo], lastPath: String?) -> SerialPortInfo? {
        ports.first { $0.path == lastPath } ?? sorted(ports).first
    }

    private static func property(_ key: String, of service: io_object_t, searchingParents: Bool = false) -> Any? {
        if searchingParents {
            let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, nil, options)
        }
        return IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue()
    }
}
