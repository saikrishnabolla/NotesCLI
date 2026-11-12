import AppKit
import PencilKit
import XCTest
@testable import NotesNative

/// Untrusted SVG must fail with a clear error instead of trapping, hanging, or exhausting memory.
final class SVGLimitTests: XCTestCase {
    private func svg(_ body: String, viewBox: String = "0 0 100 100") -> Data {
        Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="\##(viewBox)">\##(body)</svg>"##.utf8)
    }

    private func assertInvalid(_ data: Data, options: SVGDrawingOptions = .init(), _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SVGDrawingConverter.parse(data, options: options), file: file, line: line) { error in
            XCTAssertEqual((error as? SVGDrawingError)?.errorDescription, message, file: file, line: line)
        }
    }

    func testRejectsHugeAndNonFiniteCoordinates() {
        assertInvalid(svg(#"<line x1="0" y1="0" x2="1e300" y2="0" stroke="black"/>"#),
                      "SVG coordinates must be finite and within ±1000000.")
        assertInvalid(svg(#"<g transform="scale(1e200)"><line x1="0" y1="0" x2="1e200" y2="0" stroke="black"/></g>"#),
                      "SVG coordinates must be finite and within ±1000000.")
        assertInvalid(svg(#"<path d="M0 0 L 1e999 0" stroke="black"/>"#),
                      "SVG coordinates must be finite and within ±1000000.")
    }

    func testRejectsTooManyElements() {
        assertInvalid(svg(String(repeating: #"<g/>"#, count: 20_000)), "The SVG has more than 20000 elements.")
    }

    func testRejectsTooManyPoints() {
        let curves = String(repeating: " C1 1 2 2 3 3", count: 12_501)
        assertInvalid(svg(#"<path d="M0 0\#(curves)" stroke="black" fill="none"/>"#), "The SVG has more than 200000 points.")
    }

    func testRejectsTooManyStrokes() {
        assertInvalid(svg(String(repeating: #"<line x1="0" y1="0" x2="1" y2="1" stroke="black"/>"#, count: 10_000) +
                          #"<path d="M0 0 L1 1"#  + String(repeating: " M0 0 L1 1", count: 10_000) + #"" stroke="black"/>"#),
                      "The SVG has more than 20000 strokes.")
    }

    func testRejectsUnboundedHatching() {
        assertInvalid(svg(#"<polygon points="0,0 1,0 1,100000 0,100000" fill="black"/>"#, viewBox: "0 0 1 100000"),
                      options: .init(fill: .hatch), "Hatch fill would draw more than 10000 lines.")
    }

    func testRejectsOversizedCanvasAndStrokeWidth() {
        let line = svg(#"<line x1="0" y1="0" x2="10" y2="10" stroke="black"/>"#)
        assertInvalid(line, options: .init(size: DrawingSize(width: 1e9, height: 10)), "Drawing size must be at most 20000 × 20000.")
        assertInvalid(line, options: .init(width: .infinity), "Stroke width must be finite and at most 1000.")
        assertInvalid(svg(#"<line x1="0" y1="0" x2="10" y2="10" stroke="black" stroke-width="1e9"/>"#),
                      "Stroke width must be finite and at most 1000.")
    }

    func testExportFormatsHugeCoordinatesWithoutTrapping() {
        let points = [1e19, 1e19 + 4096].map {
            PKStrokePoint(location: CGPoint(x: $0, y: 0), timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
        let output = SVGDrawingConverter.svg(from: PKDrawing(strokes: [stroke]))
        XCTAssertTrue(output.contains(#"<path d="M9.999999980506448e+18 0 L9.999999980506448e+18 0""#), output)
    }
}
