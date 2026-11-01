import Foundation

/// CRC-32 (ISO 3309), the checksum PNG chunks and ZIP entries carry. Feed it data in pieces with `update`.
public struct CRC32: Sendable {
    public private(set) var value: UInt32 = 0

    public init() {}

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var crc = ~value
        for byte in bytes {
            crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        value = ~crc
    }

    public mutating func update(_ data: some DataProtocol) {
        for region in data.regions {
            region.withUnsafeBytes { update($0) }
        }
    }

    public static func checksum(_ data: some DataProtocol) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }

    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }
}
