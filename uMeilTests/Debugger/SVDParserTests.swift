import Foundation
import Testing
@testable import uMeil

/// Tests for reading CMSIS-SVD files and decoding bit fields (M7).
struct SVDParserTests {
    private static let sample = """
    <?xml version="1.0" encoding="utf-8"?>
    <device schemaVersion="1.1">
      <name>TEST</name>
      <size>32</size>
      <access>read-write</access>
      <resetValue>0</resetValue>
      <peripherals>
        <peripheral>
          <name>GPIOA</name>
          <groupName>GPIO</groupName>
          <baseAddress>0x40058000</baseAddress>
          <registers>
            <register>
              <name>DIR</name>
              <addressOffset>0x400</addressOffset>
              <fields>
                <field><name>P%s</name><bitOffset>0</bitOffset><bitWidth>1</bitWidth>
                  <dim>8</dim><dimIncrement>1</dimIncrement></field>
              </fields>
            </register>
            <register>
              <name>DATA</name>
              <addressOffset>0x3FC</addressOffset>
            </register>
            <register>
              <name>RIS</name>
              <addressOffset>0x414</addressOffset>
              <access>read-only</access>
            </register>
          </registers>
        </peripheral>
        <peripheral derivedFrom="GPIOA">
          <name>GPIOB</name>
          <baseAddress>0x40059000</baseAddress>
        </peripheral>
        <peripheral>
          <name>UART0</name>
          <baseAddress>0x4000C000</baseAddress>
          <size>16</size>
          <registers>
            <register>
              <name>DR</name>
              <addressOffset>0x0</addressOffset>
              <readAction>modify</readAction>
            </register>
            <register>
              <name>CTL</name>
              <addressOffset>0x30</addressOffset>
              <resetValue>0x300</resetValue>
              <fields>
                <field><name>UARTEN</name><bitRange>[0:0]</bitRange></field>
                <field><name>WLEN</name><lsb>5</lsb><msb>6</msb>
                  <enumeratedValues>
                    <enumeratedValue><name>5BIT</name><value>0</value></enumeratedValue>
                    <enumeratedValue><name>8BIT</name><value>0x3</value></enumeratedValue>
                    <enumeratedValue><name>7BIT</name><value>#10</value></enumeratedValue>
                  </enumeratedValues>
                </field>
              </fields>
            </register>
          </registers>
        </peripheral>
        <peripheral>
          <name>DMA</name>
          <baseAddress>0x400FF000</baseAddress>
          <registers>
            <cluster>
              <name>CH%s</name>
              <dim>2</dim>
              <dimIncrement>0x10</dimIncrement>
              <addressOffset>0x100</addressOffset>
              <register><name>SRC</name><addressOffset>0x0</addressOffset></register>
              <register><name>DST</name><addressOffset>0x4</addressOffset></register>
            </cluster>
          </registers>
        </peripheral>
      </peripherals>
    </device>
    """

    private func sampleDevice() throws -> SVDDevice {
        try SVDParser.parse(Data(Self.sample.utf8))
    }

    @Test func readsPeripheralsRegistersAndAddressesInAddressOrder() throws {
        let device = try sampleDevice()
        #expect(device.name == "TEST")
        #expect(device.peripherals.map(\.name) == ["GPIOA", "GPIOB", "UART0", "DMA"])

        let gpio = try #require(device.peripheral(named: "gpioa"))
        #expect(gpio.groupName == "GPIO")
        #expect(gpio.registers.map(\.name) == ["DATA", "DIR", "RIS"])
        let dir = try #require(gpio.register(named: "DIR"))
        #expect(gpio.address(of: dir) == 0x4005_8400)
        #expect(dir.size == 32)
        #expect(dir.resetValue == 0)
        #expect(gpio.register(named: "RIS")?.access == .readOnly)
    }

    @Test func expandsFieldArraysAndInheritsDerivedPeripherals() throws {
        let device = try sampleDevice()
        let dir = try #require(device.peripheral(named: "GPIOA")?.register(named: "DIR"))
        #expect(dir.fields.map(\.name) == ["P0", "P1", "P2", "P3", "P4", "P5", "P6", "P7"])
        #expect(dir.fields.map(\.bitOffset) == Array(0..<8))

        let portB = try #require(device.peripheral(named: "GPIOB"))
        #expect(portB.baseAddress == 0x4005_9000)
        #expect(portB.groupName == "GPIO")
        #expect(portB.registers.map(\.name) == ["DATA", "DIR", "RIS"])
        #expect(portB.registers.first.map(portB.address(of:)) == 0x4005_93FC)
    }

    @Test func readsBitRangesInEveryFormAndEnumeratedValues() throws {
        let uart = try #require(try sampleDevice().peripheral(named: "UART0"))
        let ctl = try #require(uart.register(named: "CTL"))
        #expect(ctl.size == 16)
        #expect(ctl.resetValue == 0x300)

        let enable = try #require(ctl.fields.first { $0.name == "UARTEN" })
        #expect(enable.bitOffset == 0)
        #expect(enable.bitWidth == 1)
        #expect(enable.bitRangeText == "[0]")

        let length = try #require(ctl.fields.first { $0.name == "WLEN" })
        #expect(length.bitOffset == 5)
        #expect(length.bitWidth == 2)
        #expect(length.bitRangeText == "[6:5]")
        #expect(length.enumeratedName(for: 3) == "8BIT")
        #expect(length.enumeratedName(for: 2) == "7BIT")
        #expect(length.enumeratedName(for: 1) == nil)
    }

    @Test func marksRegistersWhoseReadHasSideEffects() throws {
        let uart = try #require(try sampleDevice().peripheral(named: "UART0"))
        #expect(uart.register(named: "DR")?.readHasSideEffects == true)
        #expect(uart.register(named: "CTL")?.readHasSideEffects == false)
    }

    @Test func flattensClusterArrays() throws {
        let dma = try #require(try sampleDevice().peripheral(named: "DMA"))
        #expect(dma.registers.map(\.name) == ["CH0_SRC", "CH0_DST", "CH1_SRC", "CH1_DST"])
        #expect(dma.registers.map(\.addressOffset) == [0x100, 0x104, 0x110, 0x114])
    }

    @Test func refusesFilesThatAreNotSVDAndUnknownBases() {
        #expect(throws: SVDParser.Failure.notSVD) {
            try SVDParser.parse(Data("<project/>".utf8))
        }
        let orphan = """
        <device><name>X</name><peripherals>
          <peripheral derivedFrom="NOPE"><name>B</name><baseAddress>0</baseAddress></peripheral>
        </peripherals></device>
        """
        #expect(throws: SVDParser.Failure.unknownBase(peripheral: "B", derivedFrom: "NOPE")) {
            try SVDParser.parse(Data(orphan.utf8))
        }
    }

    // MARK: - Bit fields

    @Test func fieldsReadAndWriteTheirBitsOnly() {
        let field = SVDField(
            name: "OSCSRC", description: nil, bitOffset: 20, bitWidth: 4,
            access: .readWrite, enumeratedValues: []
        )
        #expect(field.mask == 0x00F0_0000)
        #expect(field.value(in: 0x1234_5678) == 0x3)
        #expect(field.inserting(0xA, into: 0x1234_5678) == 0x12A4_5678)
        // Bits that do not fit are dropped instead of spilling into neighbours.
        #expect(field.inserting(0x1F, into: 0) == 0x00F0_0000)
    }

    @Test func numbersInEverySVDNotation() {
        #expect(SVDParser.number("0x1F") == 31)
        #expect(SVDParser.number("0X1f") == 31)
        #expect(SVDParser.number("#101") == 5)
        #expect(SVDParser.number("0b101") == 5)
        #expect(SVDParser.number(" 42 ") == 42)
        #expect(SVDParser.number("#1x1") == nil)
    }

    // MARK: - The shipped file

    @Test func shippedTM4C1294FileDescribesTheLaunchPadsLEDAndClockRegisters() throws {
        let url = SVDDevice.bundledFile()
        let device = try SVDParser.parse(contentsOf: url)
        #expect(device.name == "TM4C1294NCPDT")

        // LED D1 on the EK-TM4C1294XL is PN1.
        let portN = try #require(device.peripheral(named: "GPIO_PORTN"))
        #expect(portN.baseAddress == 0x4006_4000)
        let data = try #require(portN.register(named: "DATA"))
        #expect(portN.address(of: data) == 0x4006_43FC)
        #expect(data.fields.map(\.name).contains("P1"))

        let sysctl = try #require(device.peripheral(named: "SYSCTL"))
        let gates = try #require(sysctl.register(named: "RCGCGPIO"))
        #expect(sysctl.address(of: gates) == 0x400F_E608)
        #expect(gates.fields.first { $0.name == "R12" }?.bitOffset == 12)

        let clock = try #require(sysctl.register(named: "RSCLKCFG"))
        let source = try #require(clock.fields.first { $0.name == "OSCSRC" })
        #expect(source.bitRangeText == "[23:20]")
        #expect(source.enumeratedName(for: 3) == "MOSC")

        let uart = try #require(device.peripheral(named: "UART0"))
        #expect(uart.register(named: "DR")?.readHasSideEffects == true)
        #expect(uart.register(named: "CTL")?.readHasSideEffects == false)
    }
}
