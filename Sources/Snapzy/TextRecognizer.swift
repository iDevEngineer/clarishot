import CoreGraphics
import Vision

/// On-device text and QR/barcode reading for Capture Text (OCR).
enum TextRecognizer {
    /// Reads the text in `image`, keeping line breaks (or joining lines with spaces) and
    /// leaving a blank line between paragraphs. Any QR codes or barcodes are added as
    /// their contents, e.g. a link. Runs synchronously; call off the main thread.
    static func recognize(_ image: CGImage, keepLineBreaks: Bool = true) -> String {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        let codeRequest = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([textRequest, codeRequest])

        let text = format(textRequest.results ?? [], keepLineBreaks: keepLineBreaks)
        var codes: [String] = []
        for payload in (codeRequest.results ?? []).compactMap(\.payloadStringValue) where !codes.contains(payload) {
            codes.append(payload)
        }
        return ([text] + codes).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Groups lines into blocks (lines stacked under each other that overlap sideways, so
    /// side-by-side columns stay apart), reads blocks top-left first, and leaves a blank
    /// line between blocks and wherever the gap above a line is clearly bigger than usual.
    static func format(_ observations: [VNRecognizedTextObservation], keepLineBreaks: Bool) -> String {
        let lines = observations
            .compactMap { o in o.topCandidates(1).first.map { (box: o.boundingBox, text: $0.string) } }
            .sorted { $0.box.midY > $1.box.midY } // Vision's origin is bottom-left
        guard !lines.isEmpty else { return "" }
        let typicalHeight = lines.map(\.box.height).sorted()[lines.count / 2]

        // Each line joins the block whose last line sits just above it and overlaps it sideways.
        var blocks: [[(box: CGRect, text: String)]] = []
        for line in lines {
            if let index = blocks.lastIndex(where: { block in
                let last = block[block.count - 1].box
                let overlap = min(last.maxX, line.box.maxX) - max(last.minX, line.box.minX)
                return overlap > 0 && last.minY - line.box.maxY < typicalHeight * 12
            }) {
                blocks[index].append(line)
            } else {
                blocks.append([line])
            }
        }
        blocks.sort { a, b in
            let ta = a[0].box, tb = b[0].box
            // Same band of the page: left first; otherwise top first.
            if abs(ta.maxY - tb.maxY) < typicalHeight * 2 { return ta.minX < tb.minX }
            return ta.maxY > tb.maxY
        }

        var paragraphs: [[String]] = []
        for block in blocks {
            let gaps = zip(block, block.dropFirst()).map { max($0.box.minY - $1.box.maxY, 0) }
            let typicalGap = gaps.isEmpty ? 0 : gaps.sorted()[gaps.count / 2]
            paragraphs.append([block[0].text])
            for (index, line) in block.dropFirst().enumerated() {
                if gaps.count > 1 && gaps[index] > max(typicalGap * 1.8, typicalHeight * 1.2) { paragraphs.append([]) }
                paragraphs[paragraphs.count - 1].append(line.text)
            }
        }
        let separator = keepLineBreaks ? "\n" : " "
        return paragraphs.map { $0.joined(separator: separator) }.joined(separator: "\n\n")
    }
}
