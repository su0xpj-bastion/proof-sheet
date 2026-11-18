import CoreGraphics
import CoreImage
import Foundation

/// Applies a PhotoRecipe with Core Image. Order: colour, filter, quarter turns, straighten, crop, scale.
public enum Renderer {
    public static let context = CIContext(options: [.workingColorSpace: PhotoFixture.linearSRGB, .cacheIntermediates: false])

    public static func render(_ input: CIImage, _ r: PhotoRecipe) -> CIImage {
        var img = color(input, r)
        if FaultInjection.on(.recipeAppliedTwice) { img = color(img, r) }
        img = filter(img, r.filter)
        img = geometry(img, r)
        return img
    }

    /// Render then scale so the longer side is `maxDimension` (a proxy, a thumbnail, a size-limited export).
    public static func render(_ input: CIImage, _ r: PhotoRecipe, maxDimension: CGFloat?) -> CIImage {
        let out = render(input, r)
        guard let m = maxDimension else { return out }
        let s = m / max(out.extent.width, out.extent.height)
        guard s < 1 else { return out }
        return scaled(out, s)
    }

    public static func scaled(_ img: CIImage, _ s: CGFloat) -> CIImage {
        let t = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        return t.cropped(to: CGRect(x: 0, y: 0, width: (img.extent.width * s).rounded(), height: (img.extent.height * s).rounded()))
    }

    static func color(_ input: CIImage, _ r: PhotoRecipe) -> CIImage {
        var img = input
        if r.exposure != 0 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: r.exposure]) }
        if r.warmth != 0 {
            // Telling Core Image the scene was lit warmer than 6500 K shifts the result warm.
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(6500 + 2500 * r.warmth), y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if r.contrast != 1 || r.saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: r.contrast, kCIInputSaturationKey: r.saturation, kCIInputBrightnessKey: 0,
            ])
        }
        return img
    }

    static func filter(_ img: CIImage, _ f: PhotoFilter) -> CIImage {
        switch f {
        case .none: return img
        case .mono: return img.applyingFilter("CIPhotoEffectMono")
        case .sepia: return img.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 1.0])
        case .swapLUT:
            // 2x2x2 cube, red index fastest. Output (r,g,b) = input (b,g,r); exact under trilinear interpolation.
            var cube: [Float] = []
            for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += [Float(b), Float(g), Float(r), 1] } } }
            let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
            return img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": 2, "inputCubeData": data])
        }
    }

    static func geometry(_ input: CIImage, _ r: PhotoRecipe) -> CIImage {
        var img = input
        let turns = ((r.quarterTurns % 4) + 4) % 4
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        if turns != 0 { img = img.oriented(orientations[turns]) }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let frame = img.extent
        if r.straighten != 0 {
            let theta = CGFloat(r.straighten * .pi / 180), w = frame.width, h = frame.height
            // Smallest scale at which the rotated image still covers every corner of the frame.
            let s = cos(abs(theta)) + max(w / h, h / w) * sin(abs(theta))
            let t = CGAffineTransform(translationX: frame.midX, y: frame.midY)
                .rotated(by: -theta).scaledBy(x: s, y: s).translatedBy(x: -frame.midX, y: -frame.midY)
            img = img.clampedToExtent().transformed(by: t).cropped(to: frame)
        }
        if r.crop != .full {
            let c = r.crop
            // Recipe y runs top-down; Core Image y runs bottom-up.
            let rect = CGRect(x: frame.minX + CGFloat(c.x) * frame.width,
                              y: frame.minY + CGFloat(1 - c.y - c.h) * frame.height,
                              width: CGFloat(c.w) * frame.width, height: CGFloat(c.h) * frame.height)
            img = img.cropped(to: rect.integral.intersection(frame))
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        return img
    }
}

/// Float RGBA readback for measuring renders, with (0,0) at the top-left.
public struct Pixels {
    public let width: Int, height: Int
    public let data: [Float]

    public init(_ img: CIImage, space: CGColorSpace = PhotoFixture.srgb) {
        let e = img.extent.integral
        let w = Int(e.width), h = Int(e.height)
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            Renderer.context.render(img, toBitmap: raw.baseAddress!, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: space)
        }
        width = w; height = h; data = buf
    }

    public init(_ cg: CGImage, space: CGColorSpace = PhotoFixture.srgb) { self.init(CIImage(cgImage: cg), space: space) }

    /// Mean RGB over a (2r+1)^2 box centred at (x, y), y measured from the top.
    public func rgb(_ x: Int, _ y: Int, r: Int = 2) -> [Double] {
        var s = [0.0, 0.0, 0.0], n = 0.0
        for yy in max(0, y - r)...min(height - 1, y + r) {
            for xx in max(0, x - r)...min(width - 1, x + r) {
                let o = (yy * width + xx) * 4
                s[0] += Double(data[o]); s[1] += Double(data[o + 1]); s[2] += Double(data[o + 2]); n += 1
            }
        }
        return s.map { $0 / n }
    }

    /// Source position named by a coordinate-image pixel: (x, y) in 0...1, y from the top.
    public func sourcePosition(_ x: Int, _ y: Int) -> (Double, Double) {
        let c = rgb(x, y, r: 1)
        return (c[0], c[1])
    }

    /// Where each output corner came from: top-left, top-right, bottom-left, bottom-right.
    public func cornerSources(inset: Int = 3) -> [(Double, Double)] {
        [sourcePosition(inset, inset), sourcePosition(width - 1 - inset, inset),
         sourcePosition(inset, height - 1 - inset), sourcePosition(width - 1 - inset, height - 1 - inset)]
    }
}
