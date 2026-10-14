import AppKit
import CoreImage
import Vision

/// Lifts the main subject(s) out of an image with Apple's on-device Vision model, leaving the
/// background transparent and cropping to the subject. nil if nothing stands out.
enum BackgroundRemover {
    static func removeBackground(_ image: CGImage, cropToSubject: Bool = true) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first, !result.allInstances.isEmpty,
              let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                           croppedToInstancesExtent: cropToSubject)
        else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8,
                                         colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Runs off the main thread.
    static func removeBackgroundAsync(_ image: CGImage, cropToSubject: Bool = true) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: removeBackground(image, cropToSubject: cropToSubject))
            }
        }
    }
}

/// Finds text that looks private (emails, phone numbers, card numbers, IP addresses, links,
/// API keys and tokens) in an image, returning where it sits in image points (top-left origin).
enum SensitiveDataFinder {
    struct Match { let rect: CGRect; let kind: String }

    static func find(in image: CGImage, pointSize: CGSize) -> [Match] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // keep keys and numbers exactly as written
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var matches: [Match] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            for (range, kind) in sensitiveRanges(in: text) {
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                // Vision: normalised, bottom-left origin → image points, top-left origin.
                let rect = CGRect(x: box.minX * pointSize.width, y: (1 - box.maxY) * pointSize.height,
                                  width: box.width * pointSize.width, height: box.height * pointSize.height)
                matches.append(Match(rect: rect.insetBy(dx: -3, dy: -3), kind: kind))
            }
        }
        return matches
    }

    static func findAsync(in image: CGImage, pointSize: CGSize) async -> [Match] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: find(in: image, pointSize: pointSize))
            }
        }
    }

    private static let patterns: [(String, String)] = [
        ("Email", #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        ("Card number", #"\b(?:\d[ -]?){13,19}\b"#),
        ("IP address", #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
        ("Key", #"\b(?:sk|pk|rk|ghp|gho|xox[abpr]|AKIA|AIza)[A-Za-z0-9_\-]{12,}\b"#),
        ("Token", #"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}\b"#),
        ("Phone", #"(?:\+\d{1,3}[ .-]?)?(?:\(\d{2,4}\)[ .-]?)?\d{3,4}[ .-]\d{3,4}(?:[ .-]\d{2,4})?"#)
    ]

    private static func sensitiveRanges(in text: String) -> [(Range<String.Index>, String)] {
        var found: [(Range<String.Index>, String)] = []
        let ns = text as NSString
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range, in: text),
                      !found.contains(where: { $0.0.overlaps(range) }) else { continue }
                found.append((range, kind))
            }
        }
        return found
    }
}
