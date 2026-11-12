import AppKit
import PencilKit
import XCTest
@testable import NotesNative

final class PaperStrokeRecordTests: XCTestCase {
    private func stroke(ink: PKInk.InkType = .pen, color: NSColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                        points: [(Double, Double)] = [(10, 20), (30, 40)], width: Double = 2,
                        transform: CGAffineTransform = .identity) -> PKStroke {
        let path = PKStrokePath(controlPoints: points.enumerated().map { index, point in
            PKStrokePoint(location: CGPoint(x: point.0, y: point.1), timeOffset: Double(index) / 120,
                          size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(ink, color: color), path: path, transform: transform)
    }

    func testRecordsInkColourWidthAndTransformedPoints() {
        let records = PaperStrokeRecord.records([PKDrawing(strokes: [stroke(transform: CGAffineTransform(translationX: 5, y: 0))])])
        let expected = [PaperStrokeRecord(ink: "com.apple.ink.pen", color: [1, 0, 0, 1], points: [
            .init(x: 15, y: 20, width: 2, opacity: 1), .init(x: 35, y: 40, width: 2, opacity: 1),
        ])]
        XCTAssertNil(PaperStrokeRecord.mismatch(expected: expected, actual: records))
        XCTAssertEqual(records.first?.points.map(\.x), [15, 35])
    }

    func testSerializedRoundTripMatches() throws {
        let original = PKDrawing(strokes: [stroke(), stroke(ink: .marker, points: [(1, 1), (2, 2), (3, 3)])])
        let restored = try PKDrawing(data: original.dataRepresentation())
        XCTAssertNil(PaperStrokeRecord.mismatch(expected: PaperStrokeRecord.records([original]),
                                                actual: PaperStrokeRecord.records([restored])))
    }

    func testWholeDrawingMovedByNotesStillMatches() {
        let original = PKDrawing(strokes: [stroke(), stroke(points: [(50, 50), (60, 70)])])
        let moved = PKDrawing(strokes: [stroke(points: [(10, 13), (30, 33)]), stroke(points: [(50, 43), (60, 63)])])
        XCTAssertNil(PaperStrokeRecord.mismatch(expected: PaperStrokeRecord.records([original]), actual: PaperStrokeRecord.records([moved])))
        let oneStrokeMoved = PKDrawing(strokes: [stroke(points: [(10, 13), (30, 33)]), stroke(points: [(50, 50), (60, 70)])])
        XCTAssertEqual(PaperStrokeRecord.mismatch(expected: PaperStrokeRecord.records([original]), actual: PaperStrokeRecord.records([oneStrokeMoved])),
                       "Stroke 1 point 0 is at (50.0, 50.0); expected (50.0, 43.0).")
    }

    func testSameStrokeCountWithDifferentStrokesIsRejected() {
        let expected = PaperStrokeRecord.records([PKDrawing(strokes: [stroke()])])
        func check(_ changed: PKStroke) -> String? {
            PaperStrokeRecord.mismatch(expected: expected, actual: PaperStrokeRecord.records([PKDrawing(strokes: [changed])]))
        }
        XCTAssertEqual(check(stroke(points: [(10, 20), (30, 41)])), "Stroke 0 point 1 is at (30.0, 41.0); expected (30.0, 40.0).")
        XCTAssertEqual(check(stroke(ink: .pencil)), "Stroke 0 uses ink com.apple.ink.pencil; expected com.apple.ink.pen.")
        XCTAssertEqual(check(stroke(color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))),
                       "Stroke 0 colour is [0.0, 0.0, 1.0, 1.0]; expected [1.0, 0.0, 0.0, 1.0].")
        XCTAssertEqual(check(stroke(width: 4)), "Stroke 0 point 0 width is 4.0; expected 2.0.")
        XCTAssertEqual(check(stroke(points: [(10, 20), (30, 40), (50, 60)])), "Stroke 0 has 3 points; expected 2.")
        XCTAssertEqual(PaperStrokeRecord.mismatch(expected: expected, actual: []), "Expected 1 strokes; read back 0.")
    }
}
