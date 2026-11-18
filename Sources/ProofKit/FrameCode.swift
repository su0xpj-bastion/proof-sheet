/// A frame number drawn as a block barcode, readable after compression.
///
/// 32 blocks (8 x 4, 40 px each): 24 bits of frame number, then a CRC-8.
/// Any single flipped block fails the CRC, so a misread is reported, never trusted.
public enum FrameCode {
    public static let width = 640, height = 360
    public static let cols = 8, rows = 4, block = 40
    static let originX = 160, originY = 100, quiet = 12
    public static let maxID = (1 << 24) - 1

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for b in bytes {
            crc ^= b
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    static func idBytes(_ id: Int) -> [UInt8] { [UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)] }

    public static func bits(for id: Int) -> [Bool] {
        precondition(id >= 0 && id <= maxID)
        let word = (UInt32(id) << 8) | UInt32(crc8(idBytes(id)))
        return (0..<32).map { word & (1 << (31 - UInt32($0))) != 0 }
    }

    public static func decode(bits: [Bool]) -> Int? {
        guard bits.count == 32 else { return nil }
        let word = bits.reduce(UInt32(0)) { ($0 << 1) | ($1 ? 1 : 0) }
        let id = Int(word >> 8)
        return UInt8(word & 0xFF) == crc8(idBytes(id)) ? id : nil
    }

    /// Draw frame `id` into a 640x360 BGRA buffer: tinted background, white quiet zone, blocks.
    public static func draw(id: Int, into p: UnsafeMutablePointer<UInt8>, bytesPerRow: Int) {
        let tint = (UInt8((id * 37) % 200 + 30), UInt8((id * 11) % 200 + 30), UInt8((id * 5) % 200 + 30))
        let codeW = cols * block, codeH = rows * block
        let bits = self.bits(for: id)
        for y in 0..<height {
            for x in 0..<width {
                var bgr = tint
                let cx = x - originX, cy = y - originY
                if cx >= -quiet && cx < codeW + quiet && cy >= -quiet && cy < codeH + quiet {
                    bgr = (235, 235, 235)
                    if cx >= 0 && cx < codeW && cy >= 0 && cy < codeH && bits[(cy / block) * cols + cx / block] {
                        bgr = (16, 16, 16)
                    }
                }
                let o = y * bytesPerRow + x * 4
                p[o] = bgr.0; p[o + 1] = bgr.1; p[o + 2] = bgr.2; p[o + 3] = 255
            }
        }
    }

    /// Read the frame number back; nil when the CRC fails.
    public static func read(from p: UnsafePointer<UInt8>, bytesPerRow: Int) -> Int? {
        var bits: [Bool] = []
        for i in 0..<(cols * rows) {
            let bx = originX + (i % cols) * block + block / 4, by = originY + (i / cols) * block + block / 4
            var sum = 0, n = 0
            for y in by..<(by + block / 2) {
                for x in bx..<(bx + block / 2) {
                    let o = y * bytesPerRow + x * 4
                    sum += (Int(p[o + 2]) * 299 + Int(p[o + 1]) * 587 + Int(p[o]) * 114) / 1000
                    n += 1
                }
            }
            bits.append(sum / n < 128)
        }
        return decode(bits: bits)
    }
}
