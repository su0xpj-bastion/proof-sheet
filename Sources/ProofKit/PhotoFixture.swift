import CoreGraphics
import Foundation
import ImageIO

/// Test images whose pixels say where they came from.
///
/// Coordinate image: red = x / width, green = y / height, blue = 0.5, so any output pixel
/// names the source pixel it shows. Crop, rotate, straighten and EXIF orientation are read
/// back exactly from four corners, with no golden images.
public enum PhotoFixture {
    public static let size = CGSize(width: 1200, height: 800)
    public static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    public static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    public static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// 16-bit so position survives to within a fraction of a pixel.
    public static func coordinateImage(width: Int = 1200, height: Int = 800) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        let p = ctx.data!.assumingMemoryBound(to: UInt16.self)
        let row = ctx.bytesPerRow / 2
        for y in 0..<height {
            // CGContext row 0 is the top of the image.
            for x in 0..<width {
                let o = y * row + x * 4
                p[o] = UInt16((Double(x) + 0.5) / Double(width) * 65535)
                p[o + 1] = UInt16((Double(y) + 0.5) / Double(height) * 65535)
                p[o + 2] = 32768
                p[o + 3] = 65535
            }
        }
        return ctx.makeImage()!
    }

    /// Named colour patches, each 100x100, laid out in a row on a 1000x200 chart.
    public enum Patch: Int, CaseIterable {
        case gray18, gray50, dark, light, red, blue, p3Green, skin
        public var rect: CGRect { CGRect(x: rawValue % 8 * 125 + 12, y: 50, width: 100, height: 100) }
        public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    }

    /// Display P3 chart. `p3Green` is P3 (0,1,0): outside sRGB, so it shows whether gamut survives.
    public static func colorChart() -> CGImage {
        let ctx = CGContext(data: nil, width: 1000, height: 200, bitsPerComponent: 16, bytesPerRow: 0, space: p3,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: p3, components: [0.2, 0.2, 0.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 200))
        for patch in Patch.allCases {
            ctx.setFillColor(patchColor(patch))
            ctx.fill(flip(patch.rect, height: 200))
        }
        return ctx.makeImage()!
    }

    public static func patchColor(_ p: Patch) -> CGColor {
        switch p {
        case .gray18: return CGColor(colorSpace: srgb, components: [0.46, 0.46, 0.46, 1])!
        case .gray50: return CGColor(colorSpace: srgb, components: [0.5, 0.5, 0.5, 1])!
        case .dark: return CGColor(colorSpace: srgb, components: [0.2, 0.2, 0.2, 1])!
        case .light: return CGColor(colorSpace: srgb, components: [0.8, 0.8, 0.8, 1])!
        case .red: return CGColor(colorSpace: srgb, components: [0.8, 0.1, 0.1, 1])!
        case .blue: return CGColor(colorSpace: srgb, components: [0.1, 0.1, 0.8, 1])!
        case .p3Green: return CGColor(colorSpace: p3, components: [0, 1, 0, 1])!
        case .skin: return CGColor(colorSpace: srgb, components: [0.85, 0.65, 0.5, 1])!
        }
    }

    /// Linear-light patches at 0.5, 1, 2 and 4 (x diffuse white), stored as 32-bit float.
    public static let hdrLevels: [Float] = [0.5, 1, 2, 4]
    public static func hdrImage() -> CGImage {
        let w = 400, h = 100
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: 0, space: linearSRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        let p = ctx.data!.assumingMemoryBound(to: Float.self)
        let row = ctx.bytesPerRow / 4
        for y in 0..<h {
            for x in 0..<w {
                let v = hdrLevels[x / 100], o = y * row + x * 4
                p[o] = v; p[o + 1] = v; p[o + 2] = v; p[o + 3] = 1
            }
        }
        return ctx.makeImage()!
    }

    static func flip(_ r: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    /// Camera-style metadata: capture date, lens, maker, and a GPS fix.
    public static let gps: [String: Any] = [
        kCGImagePropertyGPSLatitude as String: 37.3349, kCGImagePropertyGPSLatitudeRef as String: "N",
        kCGImagePropertyGPSLongitude as String: 122.009, kCGImagePropertyGPSLongitudeRef as String: "W",
    ]
    public static let cameraMetadata: [String: Any] = [
        kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifDateTimeOriginal as String: "2026:11:18 09:41:00",
            kCGImagePropertyExifLensModel as String: "ProofSheet Fixture 26mm f/1.6",
        ],
        kCGImagePropertyTIFFDictionary as String: [
            kCGImagePropertyTIFFMake as String: "ProofSheet", kCGImagePropertyTIFFModel as String: "Fixture",
        ],
        kCGImagePropertyGPSDictionary as String: gps,
    ]
}
