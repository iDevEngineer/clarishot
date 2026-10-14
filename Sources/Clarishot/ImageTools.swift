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
        let lines = (request.results ?? []).compactMap { obs -> (VNRecognizedText, CGRect)? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return (candidate, toPoints(obs.boundingBox, pointSize))
        }

        var matches: [Match] = []
        func add(_ rect: CGRect, _ kind: String) {
            let padded = rect.insetBy(dx: -3, dy: -3)
            // Skip only if fully covered already; otherwise merge with every box it touches,
            // so the whole detected area is always covered.
            if matches.contains(where: { $0.rect.contains(padded) }) { return }
            var merged = padded
            var kind = kind
            matches.removeAll { existing in
                guard existing.rect.intersects(merged) else { return false }
                merged = merged.union(existing.rect)
                kind = existing.kind
                return true
            }
            matches.append(Match(rect: merged, kind: kind))
        }

        for (candidate, lineRect) in lines {
            let text = candidate.string
            // 1. Patterns: emails, keys, card numbers…
            for (range, kind) in sensitiveRanges(in: text) {
                if let box = try? candidate.boundingBox(for: range)?.boundingBox { add(toPoints(box, pointSize), kind) }
            }
            // 2. "Password: hunter2" in one line: hide what follows the label.
            if let label = labelMatch(in: text), label.upperBound < text.endIndex {
                let value = text[label.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " :=\t"))
                if !value.isEmpty, let range = text.range(of: value, range: label.upperBound..<text.endIndex),
                   let box = try? candidate.boundingBox(for: range)?.boundingBox {
                    add(toPoints(box, pointSize), "Labelled value")
                }
            }
            // 3. A label on its own ("Password") with the value elsewhere on the same row.
            guard isLabelOnly(text) else { continue }
            for (other, otherRect) in lines where otherRect.minX > lineRect.maxX - 2 && other.string != text {
                let sameRow = abs(otherRect.midY - lineRect.midY) < max(lineRect.height, otherRect.height) * 0.6
                if sameRow { add(otherRect, "Labelled value") }
            }
        }
        return matches
    }

    /// Vision's normalised, bottom-left box → image points, top-left origin.
    private static func toPoints(_ box: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width,
               height: box.height * size.height)
    }

    /// Words that mark the next value as private.
    private static let labelPattern =
        #"(?i)^\s*(pass ?word|passcode|pwd|pin( code)?|secret|api ?key|access ?key|private ?key|token|user ?name|username|login|e-?mail|account( number| no\.?)?|card( number)?|cvv|cvc|iban|sort code|routing( number)?|ssn|social security|national insurance|ni number|recovery (code|key)|seed phrase|one-?time code|otp)(?=\s|:|=|$)\s*[:=]?"#

    private static func labelMatch(in text: String) -> Range<String.Index>? {
        text.range(of: labelPattern, options: .regularExpression)
    }

    /// The whole line is just a label (allowing a trailing colon).
    private static func isLabelOnly(_ text: String) -> Bool {
        guard let range = labelMatch(in: text) else { return false }
        let rest = text.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return rest.isEmpty
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
