// vision-ocr — minimal on-device OCR CLI over Apple's Vision framework.
// Usage: vision-ocr <image-path>
// Output: JSON array of {text, confidence, x, y, w, h} — coordinates are
// NORMALIZED with a TOP-LEFT origin (Vision's bottom-left origin is flipped
// here so downstream layout math reads like a page).
// Fail-closed: any error exits non-zero with a named reason on stderr;
// an empty page is an empty array (honest), never a fabricated result.
import Foundation
import Vision
import AppKit

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write("vision-ocr: \(reason)\n".data(using: .utf8)!)
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: vision-ocr <image-path>") }
let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path) else { fail("unreadable-image:\(path)") }
guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fail("no-cgimage:\(path)")
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false   // invoices: SKUs/amounts must not be "corrected"

let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do { try handler.perform([request]) } catch { fail("vision-perform:\(error.localizedDescription)") }

var rows: [[String: Any]] = []
for obs in request.results ?? [] {
    guard let candidate = obs.topCandidates(1).first else { continue }
    let b = obs.boundingBox   // normalized, bottom-left origin
    rows.append([
        "text": candidate.string,
        "confidence": Double(candidate.confidence),
        "x": b.origin.x,
        "y": 1.0 - b.origin.y - b.size.height,   // flip to top-left origin
        "w": b.size.width,
        "h": b.size.height,
    ])
}

guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) else {
    fail("json-encode")
}
print(String(data: data, encoding: .utf8)!)
