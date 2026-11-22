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

// swiftlint:disable file_length
extension SVDParserTests {
    // MARK: - Hardening

    @Test func refusesOversizedXMLFilesAndData() throws {
        let oversized = Data(count: SVDParser.maximumXMLBytes + 1)
        #expect(throws: SVDParser.Failure.fileTooLarge) {
            try SVDParser.parse(oversized)
        }

        let temp = try TemporaryDirectory()
        let largeFile = temp.url.appending(path: "huge.svd")
        FileManager.default.createFile(atPath: largeFile.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: largeFile)
        try handle.truncate(atOffset: UInt64(SVDParser.maximumXMLBytes + 1))
        try handle.close()

        #expect(throws: SVDParser.Failure.fileTooLarge) {
            try SVDParser.parse(contentsOf: largeFile)
        }
    }

    @Test func ignoresExternalEntitiesInSVDXML() throws {
        let temp = try TemporaryDirectory()
        let secret = temp.url.appending(path: "secret.txt")
        try Data("SECRET_TOKEN_XYZ".utf8).write(to: secret)

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE device [
          <!ENTITY xxe SYSTEM "\(secret.absoluteString)">
        ]>
        <device><name>&xxe;</name><peripherals/></device>
        """
        if let device = try? SVDParser.parse(Data(xml.utf8)) {
            #expect(!device.name.contains("SECRET_TOKEN_XYZ"))
        }
    }

    @Test func guardsIntegerOverflowsDimExplosionsAndDeepClusters() throws {
        let nestedOpen = String(repeating: "<cluster><name>C</name><addressOffset>4</addressOffset>", count: 25)
        let nestedClose = String(repeating: "</cluster>", count: 25)
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <device>
          <name>EDGE</name>
          <size>0xFFFFFFFFFFFFFFFF</size>
          <peripherals>
            <peripheral>
              <name>P%s</name>
              <baseAddress>0xFFFFFFFFFFFFFFF0</baseAddress>
              <dim>10000</dim>
              <dimIncrement>0x10</dimIncrement>
              <registers>
                <register>
                  <name>BIG</name>
                  <addressOffset>0</addressOffset>
                  <size>128</size>
                  <fields>
                    <field><name>OVF1</name><lsb>0</lsb><msb>0xFFFFFFFFFFFFFFFF</msb></field>
                    <field><name>OVF2</name><bitOffset>0xFFFFFFFFFFFFFFFF</bitOffset><bitWidth>1</bitWidth></field>
                    <field><name>OVF3</name><bitRange>[999:0]</bitRange></field>
                    <field><name>OVF4</name><bitOffset>0</bitOffset><bitWidth>1</bitWidth>
                      <dim>5000</dim><dimIncrement>1</dimIncrement></field>
                    <field><name>RANGE</name><bitOffset>0</bitOffset><bitWidth>1</bitWidth>
                      <dim>2</dim><dimIndex>0-100000</dimIndex><dimIncrement>0</dimIncrement></field>
                  </fields>
                </register>
                <register>
                  <name>R%s</name>
                  <addressOffset>0</addressOffset>
                  <dim>6000</dim>
                  <dimIncrement>4</dimIncrement>
                </register>
                \(nestedOpen)<register><name>DEEP</name><addressOffset>0</addressOffset></register>\(nestedClose)
              </registers>
            </peripheral>
          </peripherals>
        </device>
        """
        let device = try SVDParser.parse(Data(xml.utf8))
        // Base address 0xFFFFFFFFFFFFFFF0 + 0x10 wraps/overflows on step 1, so only P0 (step 0) survives.
        #expect(device.peripherals.count == 1)
        let peripheral = try #require(device.peripherals.first)
        let big = try #require(peripheral.register(named: "BIG"))
        #expect(big.size == 32)
        // OVF4 only yields bits 0..<64; RANGE has bitOffset 0 for all valid items capped <= 4096.
        #expect(big.fields.allSatisfy { (0..<64).contains($0.bitOffset) && (1...64).contains($0.bitWidth) })
        let rCount = peripheral.registers.filter { $0.name.hasPrefix("R") }.count
        #expect(rCount == SVDParser.maximumDimCount)
        #expect(!peripheral.registers.contains { $0.name.hasSuffix("DEEP") })
    }

    @Test func svdFieldBitOperationsDoNotTrapOnOutOfRangeInputs() {
        let invalidFields = [
            SVDField(
                name: "N1", description: nil, bitOffset: -1, bitWidth: 4,
                access: .readWrite, enumeratedValues: []
            ),
            SVDField(
                name: "N2", description: nil, bitOffset: 0, bitWidth: -5,
                access: .readWrite, enumeratedValues: []
            ),
            SVDField(
                name: "N3", description: nil, bitOffset: 64, bitWidth: 1,
                access: .readWrite, enumeratedValues: []
            ),
            SVDField(
                name: "N4", description: nil, bitOffset: 0, bitWidth: 0,
                access: .readWrite, enumeratedValues: []
            ),
            SVDField(
                name: "N5", description: nil, bitOffset: Int.min, bitWidth: Int.max,
                access: .readWrite, enumeratedValues: []
            )
        ]
        for field in invalidFields {
            #expect(field.mask == 0)
            #expect(field.value(in: 0xDEAD_BEEF) == 0)
            #expect(field.inserting(0xFF, into: 0x1234_5678) == 0x1234_5678)
        }

        let wideTop = SVDField(
            name: "TOP", description: nil, bitOffset: 60, bitWidth: 16, access: .readWrite, enumeratedValues: []
        )
        #expect(wideTop.mask == 0xF000_0000_0000_0000)
        #expect(wideTop.value(in: 0xA000_0000_0000_0000) == 0xA)
        #expect(wideTop.inserting(0xB, into: 0x1234) == 0xB000_0000_0000_1234)
    }

    // MARK: - Edge cases

    @Test func rejectsNegativeBitRangeWithoutTrapping() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <device schemaVersion="1.1">
          <name>BADBITS</name>
          <peripherals>
            <peripheral>
              <name>P</name>
              <baseAddress>0x40000000</baseAddress>
              <registers>
                <register>
                  <name>CTRL</name>
                  <addressOffset>0x0</addressOffset>
                  <fields>
                    <field><name>NEG</name><bitRange>[3:-1]</bitRange></field>
                    <field><name>BOTHNEG</name><bitRange>[-1:-2]</bitRange></field>
                    <field><name>OK</name><bitRange>[7:4]</bitRange></field>
                  </fields>
                </register>
              </registers>
            </peripheral>
          </peripherals>
        </device>
        """
        let device = try SVDParser.parse(Data(xml.utf8))
        let ctrl = try #require(device.peripheral(named: "P")?.register(named: "CTRL"))
        #expect(ctrl.fields.map(\.name) == ["OK"])
        #expect(ctrl.fields.first?.mask == 0xF0)
    }

    @Test func dimIndexPreservesSingleLabelAndAlwaysMatchesDimCount() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <device schemaVersion="1.1">
          <name>DIMS</name>
          <peripherals>
            <peripheral>
              <name>P</name>
              <baseAddress>0x40000000</baseAddress>
              <registers>
                <register>
                  <name>SINGLE_%s</name>
                  <addressOffset>0x0</addressOffset>
                  <dim>1</dim><dimIncrement>4</dimIncrement><dimIndex>A</dimIndex>
                </register>
                <register>
                  <name>LONG_%s</name>
                  <addressOffset>0x10</addressOffset>
                  <dim>2</dim><dimIncrement>4</dimIncrement><dimIndex>A,B,C,D</dimIndex>
                </register>
                <register>
                  <name>SHORT_%s</name>
                  <addressOffset>0x20</addressOffset>
                  <dim>3</dim><dimIncrement>4</dimIncrement><dimIndex>X,Y</dimIndex>
                </register>
                <register>
                  <name>RANGE_%s</name>
                  <addressOffset>0x30</addressOffset>
                  <dim>2</dim><dimIncrement>4</dimIncrement><dimIndex>1-5</dimIndex>
                </register>
                <register>
                  <name>MISMATCH_%s</name>
                  <addressOffset>0x40</addressOffset>
                  <dim>2</dim><dimIncrement>4</dimIncrement><dimIndex>A</dimIndex>
                </register>
              </registers>
            </peripheral>
          </peripherals>
        </device>
        """
        let device = try SVDParser.parse(Data(xml.utf8))
        let names = try #require(device.peripheral(named: "P")).registers.map(\.name)
        #expect(names == [
            "SINGLE_A",
            "LONG_A", "LONG_B",
            "SHORT_0", "SHORT_1", "SHORT_2",
            "RANGE_1", "RANGE_2",
            "MISMATCH_0", "MISMATCH_1"
        ])
    }
}
