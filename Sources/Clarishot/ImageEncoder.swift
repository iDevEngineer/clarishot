import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Encodes screenshots as PNG, JPEG, WebP or AVIF.
/// AVIF uses macOS's own encoder. WebP uses Google's libwebp, shipped inside the app
/// (Contents/Frameworks) and loaded on first use; without it WebP isn't offered.
@MainActor
enum ImageEncoder {
    /// Quality 0…1. For WebP, 1 means lossless.
    static func encode(_ image: CGImage, as format: Settings.ImageFormat, quality: Double, pointSize: CGSize) -> Data? {
        let span = Perf.begin("encode")
        defer { span.end() }
        switch format {
        case .png, .jpeg:
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = pointSize
            return format == .png
                ? rep.representation(using: .png, properties: [:])
                : rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        case .avif:
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.avif" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            return CGImageDestinationFinalize(dest) ? data as Data : nil
        case .webp:
            return WebP.encode(image, quality: quality)
        }
    }

    /// Formats this Mac can write (WebP only when the bundled library loads).
    static var available: [Settings.ImageFormat] {
        Settings.ImageFormat.allCases.filter { $0 != .webp || WebP.isAvailable }
    }
}

/// Minimal bridge to libwebp's simple encoding API, loaded with dlopen.
@MainActor
private enum WebP {
    private typealias Encode = @convention(c) (UnsafePointer<UInt8>, Int32, Int32, Int32, Float,
                                               UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> Int
    private typealias EncodeLossless = @convention(c) (UnsafePointer<UInt8>, Int32, Int32, Int32,
                                                       UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> Int
    private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void

    /// Only the signed copy inside the app. Never load from a user-writable folder such as Homebrew's:
    /// that code would run with Clarishot's Screen Recording and Accessibility permissions.
    private static let library: UnsafeMutableRawPointer? = {
        guard let path = Bundle.main.privateFrameworksURL?.appendingPathComponent("libwebp.7.dylib").path else { return nil }
        return dlopen(path, RTLD_NOW)
    }()

    static var isAvailable: Bool { library != nil }

    static func encode(_ image: CGImage, quality: Double) -> Data? {
        guard let library,
              let lossy = dlsym(library, "WebPEncodeRGBA"), let lossless = dlsym(library, "WebPEncodeLosslessRGBA"),
              let free = dlsym(library, "WebPFree") else { return nil }
        // Draw into a plain 8-bit RGBA buffer (un-premultiplied, as libwebp expects).
        let width = image.width, height = image.height, stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in Swift.stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 0 && pixels[i + 3] < 255 {
            let a = Double(pixels[i + 3]) / 255
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, Double(pixels[i + c]) / a)) }
        }
        var output: UnsafeMutablePointer<UInt8>?
        let size: Int = pixels.withUnsafeBufferPointer { buffer in
            if quality >= 0.999 {
                return unsafeBitCast(lossless, to: EncodeLossless.self)(buffer.baseAddress!, Int32(width), Int32(height),
                                                                        Int32(stride), &output)
            }
            return unsafeBitCast(lossy, to: Encode.self)(buffer.baseAddress!, Int32(width), Int32(height), Int32(stride),
                                                         Float(quality * 100), &output)
        }
        guard size > 0, let output else { return nil }
        defer { unsafeBitCast(free, to: Free.self)(output) }
        return Data(bytes: output, count: size)
    }
}
