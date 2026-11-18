import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public enum PhotoFormat: String, CaseIterable, Codable {
    case jpeg, heic, png, tiff
    public var uti: String {
        switch self {
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .png: return "public.png"
        case .tiff: return "public.tiff"
        }
    }
    public var ext: String { self == .jpeg ? "jpg" : rawValue }
}

public enum ExportGamut: String, CaseIterable, Codable { case srgb, displayP3 }
public enum ExportDynamicRange: String, CaseIterable, Codable { case sdr, preserveHDR }

public struct PhotoExportPreset: Equatable, Codable {
    public var format: PhotoFormat
    public var gamut: ExportGamut
    public var range: ExportDynamicRange
    public var maxDimension: Int?
    public init(format: PhotoFormat, gamut: ExportGamut = .displayP3, range: ExportDynamicRange = .sdr, maxDimension: Int? = nil) {
        self.format = format; self.gamut = gamut; self.range = range; self.maxDimension = maxDimension
    }
    public static let standard: [String: PhotoExportPreset] = [
        "JPEG sRGB": PhotoExportPreset(format: .jpeg, gamut: .srgb),
        "HEIC P3": PhotoExportPreset(format: .heic),
        "PNG P3": PhotoExportPreset(format: .png),
        "TIFF HDR": PhotoExportPreset(format: .tiff, range: .preserveHDR),
        "JPEG 1024": PhotoExportPreset(format: .jpeg, gamut: .srgb, maxDimension: 1024),
    ]
}

public enum PhotoIOError: Error { case unreadable(String), unwritable(String), insufficientSpace(needed: Int64, free: Int64) }

public enum PhotoIO {
    /// Decode with EXIF orientation applied, so pixels are upright like Photos shows them.
    public static func load(_ url: URL) throws -> CIImage {
        guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw PhotoIOError.unreadable(url.lastPathComponent)
        }
        return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    }

    public static func properties(_ url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        return p
    }

    public static func typeIdentifier(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceGetType(src) as String?
    }

    public static func write(_ image: CGImage, to url: URL, format: PhotoFormat, properties: [String: Any] = [:]) throws {
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.uti as CFString, 1, nil) else {
            throw PhotoIOError.unwritable(format.rawValue)
        }
        var props = properties
        if format == .jpeg || format == .heic { props[kCGImageDestinationLossyCompressionQuality as String] = 0.95 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PhotoIOError.unwritable(url.lastPathComponent) }
    }

    /// Metadata an edited export carries: everything from the original except orientation
    /// (the pixels are already upright) and, when asked, location.
    public static func exportMetadata(from original: [String: Any], removeLocation: Bool) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyMakerAppleDictionary] {
            if let v = original[key as String] { out[key as String] = v }
        }
        if var tiff = out[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        out[kCGImagePropertyOrientation as String] = 1
        if removeLocation && !FaultInjection.on(.gpsNotStripped) { out.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
        return out
    }

    /// Render the recipe at full resolution and write it with the preset.
    public static func export(_ source: URL, recipe: PhotoRecipe, preset: PhotoExportPreset, to url: URL,
                              disk: DiskBudget = .system) throws {
        let input = try load(source)
        let out = Renderer.render(input, recipe, maxDimension: preset.maxDimension.map { CGFloat($0) })
        let needed = Int64(out.extent.width * out.extent.height) * (preset.range == .preserveHDR ? 16 : 4)
        try disk.require(needed, at: url.deletingLastPathComponent())
        let cg = try cgImage(out, preset: preset, sourceIsHDR: peak(input) > PhotoIO.hdrThreshold)
        try write(cg, to: url, format: preset.format,
                  properties: exportMetadata(from: properties(source), removeLocation: recipe.removeLocation))
    }

    public static func cgImage(_ img: CIImage, preset: PhotoExportPreset, sourceIsHDR: Bool) throws -> CGImage {
        let ctx = Renderer.context
        if preset.range == .preserveHDR {
            // Linear float keeps values above 1.0 (highlights brighter than diffuse white).
            guard let cg = ctx.createCGImage(img, from: img.extent, format: .RGBAf, colorSpace: PhotoFixture.linearSRGB)
            else { throw PhotoIOError.unwritable("hdr") }
            return cg
        }
        let tonemapped = toneMap(img, sourceIsHDR: sourceIsHDR)
        switch preset.gamut {
        case .srgb:
            guard let cg = ctx.createCGImage(tonemapped, from: img.extent, format: .RGBA8, colorSpace: PhotoFixture.srgb)
            else { throw PhotoIOError.unwritable("srgb") }
            return cg
        case .displayP3:
            if FaultInjection.on(.p3ClampedToSRGB) {
                let clamped = ctx.createCGImage(tonemapped, from: img.extent, format: .RGBA8, colorSpace: PhotoFixture.srgb)!
                let p3 = CGContext(data: nil, width: clamped.width, height: clamped.height, bitsPerComponent: 16, bytesPerRow: 0,
                                   space: PhotoFixture.p3,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
                p3.draw(clamped, in: CGRect(x: 0, y: 0, width: clamped.width, height: clamped.height))
                return p3.makeImage()!
            }
            guard let cg = ctx.createCGImage(tonemapped, from: img.extent, format: .RGBA16, colorSpace: PhotoFixture.p3)
            else { throw PhotoIOError.unwritable("p3") }
            return cg
        }
    }

    /// Extended Reinhard on linear light, white point 4.0: 1.0 maps below 1, 4.0 maps to 1,
    /// so every highlight level stays distinct instead of clipping to the same white.
    public static let toneMapWhite: CGFloat = 4
    /// JPEG decoding overshoots 1.0 by ~1% and gamut conversion by ~2%; real HDR highlights are far above.
    public static let hdrThreshold: Float = 1.05

    /// Brightest channel value anywhere, in linear Rec. 2020: wide-gamut colours stay inside 0...1 there,
    /// so only real highlights (brighter than diffuse white) exceed 1.
    public static func peak(_ img: CIImage) -> Float {
        let m = img.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes {
            Renderer.context.render(m, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!)
        }
        return max(px[0], px[1], px[2])
    }

    /// SDR sources pass through (an exposure push clips, as in Photos); HDR sources are tone mapped.
    static func toneMap(_ img: CIImage, sourceIsHDR: Bool) -> CIImage {
        guard sourceIsHDR else { return img }
        if FaultInjection.on(.hdrClipped) { return img.applyingFilter("CIColorClamp") }
        // Core Image has no divide filter, so the curve x * (1 + x/W^2) / (1 + x) is baked into a colour cube.
        let n = 64
        var cube: [Float] = []
        cube.reserveCapacity(n * n * n * 4)
        // The cube maps input encoded as x/W (0...1) to Reinhard(x) (0...1).
        func f(_ i: Int) -> Float {
            let x = Float(i) / Float(n - 1) * Float(toneMapWhite), w2 = Float(toneMapWhite * toneMapWhite)
            return x * (1 + x / w2) / (1 + x)
        }
        for b in 0..<n { for g in 0..<n { for r in 0..<n { cube += [f(r), f(g), f(b), 1] } } }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        let scaledDown = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 / toneMapWhite, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 / toneMapWhite, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 / toneMapWhite, w: 0),
        ]).applyingFilter("CIColorClamp")
        return scaledDown.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": n, "inputCubeData": data])
    }
}

/// Free-space gate checked before any export starts writing. Injected in tests to simulate a full disk.
public struct DiskBudget {
    public let free: (URL) -> Int64
    public init(free: @escaping (URL) -> Int64) { self.free = free }

    public static let system = DiskBudget { url in
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(v?.volumeAvailableCapacity ?? Int.max)
    }
    public static func fixed(_ bytes: Int64) -> DiskBudget { DiskBudget { _ in bytes } }

    public func require(_ bytes: Int64, at dir: URL) throws {
        let f = free(dir)
        // Keep 2x headroom: encoders buffer before they write.
        if f < bytes * 2 { throw PhotoIOError.insufficientSpace(needed: bytes * 2, free: f) }
    }
}
