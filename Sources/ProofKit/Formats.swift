import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Live Photos: a still and a movie that share a content identifier.
/// Still: MakerApple key "17". Movie: com.apple.quicktime.content.identifier.
public enum LivePhoto {
    public static func stillProperties(id: String) -> [String: Any] {
        [kCGImagePropertyMakerAppleDictionary as String: ["17": id]]
    }

    public static func stillID(_ url: URL) -> String? {
        // ImageIO pads the stored ASCII value; the identifier itself is a UUID string.
        let raw = (PhotoIO.properties(url)[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"] as? String
        return raw.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".\0")) }
    }

    public static func movieMetadata(id: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.value = id as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    public static func movieID(_ url: URL) -> String? {
        AVURLAsset(url: url).metadata(forFormat: .quickTimeMetadata).first {
            ($0.key as? String) == "com.apple.quicktime.content.identifier"
        }?.stringValue
    }

    /// Pair stills with movies. Names are not identity: a re-export or rename keeps the ID, not the name.
    public static func pair(stills: [URL], movies: [URL]) -> [(still: URL, movie: URL)] {
        if FaultInjection.on(.livePhotoIgnoresID) {
            return stills.compactMap { s in
                movies.first { $0.deletingPathExtension().lastPathComponent == s.deletingPathExtension().lastPathComponent }.map { (s, $0) }
            }
        }
        let byID = Dictionary(movies.compactMap { m in movieID(m).map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        return stills.compactMap { s in stillID(s).flatMap { byID[$0] }.map { (s, $0) } }
    }
}

/// A minimal Linear DNG (RAW) written byte by byte: ImageIO can read DNG but cannot write it,
/// so the RAW import path would otherwise have no fixture.
public enum DNGWriter {
    public static func write(_ image: CGImage, to url: URL) throws {
        let w = image.width, h = image.height
        // Linear-light RGB16, as a RAW decoder expects after demosaic.
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                            space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let src = ctx.data!.assumingMemoryBound(to: UInt16.self)
        var pixels = Data(capacity: w * h * 6)
        for i in 0..<(w * h) {
            for c in 0..<3 { var v = src[i * 4 + c].littleEndian; pixels.append(Data(bytes: &v, count: 2)) }
        }

        var entries: [(tag: UInt16, type: UInt16, count: UInt32, payload: Data)] = []
        func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
        func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
        func short(_ tag: UInt16, _ vs: [UInt16]) { entries.append((tag, 3, UInt32(vs.count), vs.reduce(Data()) { $0 + le16($1) })) }
        func long(_ tag: UInt16, _ v: UInt32) { entries.append((tag, 4, 1, le32(v))) }
        func ascii(_ tag: UInt16, _ s: String) { let d = Data(s.utf8) + Data([0]); entries.append((tag, 2, UInt32(d.count), d)) }
        func bytes(_ tag: UInt16, _ b: [UInt8]) { entries.append((tag, 1, UInt32(b.count), Data(b))) }
        func srational(_ tag: UInt16, _ vs: [(Int32, Int32)]) {
            entries.append((tag, 10, UInt32(vs.count), vs.reduce(Data()) { $0 + le32(UInt32(bitPattern: $1.0)) + le32(UInt32(bitPattern: $1.1)) }))
        }
        func rational(_ tag: UInt16, _ vs: [(UInt32, UInt32)]) {
            entries.append((tag, 5, UInt32(vs.count), vs.reduce(Data()) { $0 + le32($1.0) + le32($1.1) }))
        }

        long(254, 0)                              // NewSubfileType: main image
        long(256, UInt32(w)); long(257, UInt32(h))
        short(258, [16, 16, 16])                  // BitsPerSample
        short(259, [1])                           // no compression
        short(262, [34892])                       // PhotometricInterpretation: LinearRaw
        ascii(271, "ProofSheet"); ascii(272, "Fixture")
        long(273, 0)                              // StripOffsets, patched below
        short(277, [3])                           // SamplesPerPixel
        long(278, UInt32(h))                      // RowsPerStrip
        long(279, UInt32(pixels.count))           // StripByteCounts
        short(284, [1])                           // PlanarConfiguration: chunky
        bytes(50706, [1, 4, 0, 0])                // DNGVersion 1.4
        bytes(50707, [1, 1, 0, 0])                // DNGBackwardVersion
        ascii(50708, "ProofSheet Fixture")        // UniqueCameraModel
        // ColorMatrix1 (XYZ -> camera under D65) is linear sRGB's own matrix, so camera RGB == linear sRGB.
        let cm: [Double] = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
        srational(50721, cm.map { (Int32(($0 * 10000).rounded()), 10000) })
        rational(50728, [(1, 1), (1, 1), (1, 1)])  // AsShotNeutral: already white balanced
        short(50778, [21])                        // CalibrationIlluminant1: D65

        entries.sort { $0.tag < $1.tag }
        let ifdOffset = 8
        let ifdSize = 2 + entries.count * 12 + 4
        var extra = Data()
        var dataOffset = ifdOffset + ifdSize
        var ifd = le16(UInt16(entries.count))
        let pixelOffset: Int = {
            var total = 0
            for e in entries where e.payload.count > 4 { total += e.payload.count + (e.payload.count & 1) }
            return dataOffset + total
        }()
        for e in entries {
            var payload = e.payload
            if e.tag == 273 { payload = le32(UInt32(pixelOffset)) }
            ifd += le16(e.tag) + le16(e.type) + le32(e.count)
            if payload.count <= 4 {
                ifd += payload + Data(repeating: 0, count: 4 - payload.count)
            } else {
                ifd += le32(UInt32(dataOffset))
                extra += payload
                if payload.count & 1 == 1 { extra.append(0) }
                dataOffset += payload.count + (payload.count & 1)
            }
        }
        ifd += le32(0)
        let file = Data([0x49, 0x49, 42, 0]) + le32(UInt32(ifdOffset)) + ifd + extra + pixels
        try file.write(to: url)
    }
}
