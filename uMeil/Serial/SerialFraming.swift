import Foundation

/// How each character is framed on the wire: the data bits, parity and stop
/// bits that follow the speed in a setting such as `115200,8,N,1`.
///
/// Both ends must agree. Most firmware uses 8 data bits, no parity and 1
/// stop bit, but some course labs set others (Lab 2 uses `38400,7,N,2`).
struct SerialFraming: Equatable, Hashable, Sendable {
    enum Parity: String, CaseIterable, Sendable {
        case none, even, odd

        /// The letter used in settings such as `8,N,1`.
        var letter: String {
            switch self {
            case .none: "N"
            case .even: "E"
            case .odd: "O"
            }
        }

        var title: String {
            switch self {
            case .none: "No Parity"
            case .even: "Even Parity"
            case .odd: "Odd Parity"
            }
        }
    }

    static let dataBitChoices = [7, 8]
    static let stopBitChoices = [1, 2]

    /// 8 data bits, no parity, 1 stop bit.
    static let standard = SerialFraming(dataBits: 8, parity: .none, stopBits: 1)

    /// 7 or 8.
    var dataBits: Int
    var parity: Parity
    /// 1 or 2.
    var stopBits: Int

    init(dataBits: Int = 8, parity: Parity = .none, stopBits: Int = 1) {
        self.dataBits = Self.dataBitChoices.contains(dataBits) ? dataBits : 8
        self.parity = parity
        self.stopBits = Self.stopBitChoices.contains(stopBits) ? stopBits : 1
    }

    /// The framing written the way the course and Tera Term write it, such as `8,N,1`.
    var summary: String {
        "\(dataBits),\(parity.letter),\(stopBits)"
    }

    /// Sets the character size, parity and stop bit flags of `attributes`
    /// to match, leaving everything else alone.
    func apply(to attributes: inout termios) {
        attributes.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB)
        attributes.c_cflag |= tcflag_t(dataBits == 7 ? CS7 : CS8)
        switch parity {
        case .none: break
        case .even: attributes.c_cflag |= tcflag_t(PARENB)
        case .odd: attributes.c_cflag |= tcflag_t(PARENB | PARODD)
        }
        if stopBits == 2 {
            attributes.c_cflag |= tcflag_t(CSTOPB)
        }
    }
}
