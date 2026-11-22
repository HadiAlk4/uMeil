import Foundation
import IOKit.usb
import Testing
@testable import uMeil

@MainActor
struct BoardMonitorTests {
    @Test func theLaunchPadsDebugProbeIsTIsICDI() {
        #expect(Board.ekTM4C1294XL.debugProbe == USBDeviceID(vendorID: 0x1CBE, productID: 0x00FD))
    }

    @Test func looksForUSBDevicesWithTheProbesVendorAndProductID() {
        let matching = USBBoardMonitor.matchingDictionary(for: USBDeviceID(vendorID: 0x1CBE, productID: 0x00FD))

        #expect(matching[kIOProviderClassKey] as? String == "IOUSBHostDevice")
        #expect(matching[kUSBVendorID] as? Int == 0x1CBE)
        #expect(matching[kUSBProductID] as? Int == 0x00FD)
        #expect(matching.count == 3)
    }

    /// No real device has this ID, so this exercises the real IOKit calls
    /// with a known answer.
    @Test func aDeviceThatIsNotPluggedInIsReportedAsAbsent() {
        let nothing = USBDeviceID(vendorID: 0xFFFE, productID: 0xFFFD)
        let monitor = USBBoardMonitor(device: nothing)
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }

        monitor.start()
        monitor.start() // Starting twice is harmless.

        #expect(!monitor.isBoardConnected)
        #expect(changes.isEmpty)
        #expect(!USBBoardMonitor.isPresent(nothing))
    }

    @Test func watchingAgreesWithAOneOffCheck() {
        let probe = Board.ekTM4C1294XL.debugProbe
        let monitor = USBBoardMonitor()

        monitor.start()

        #expect(monitor.device == probe)
        #expect(monitor.isBoardConnected == USBBoardMonitor.isPresent(probe))
    }

    @Test func stopIsIdempotentAndIgnoresStaleCallbacksAfterTeardown() {
        var monitor: USBBoardMonitor? = USBBoardMonitor(device: USBDeviceID(vendorID: 0xFFFE, productID: 0xFFFD))
        monitor?.start()
        let context = monitor?.callbackContextForTesting
        #expect(monitor?.isRunning == true)
        #expect(context != nil)

        monitor?.stop()
        monitor?.stop()
        #expect(monitor?.isRunning == false)
        #expect(monitor?.isBoardConnected == false)

        // Calling with an invalidated context after stop must be a safe no-op.
        USBBoardMonitor.dispatchNotificationForTesting(context: context)

        // Restarting after stop works, and deallocating without stop also invalidates the context.
        monitor?.start()
        let secondContext = monitor?.callbackContextForTesting
        #expect(monitor?.isRunning == true)
        #expect(secondContext != nil)
        weak var weakMonitor = monitor
        monitor = nil
        #expect(weakMonitor == nil)

        USBBoardMonitor.dispatchNotificationForTesting(context: secondContext)
    }
}
