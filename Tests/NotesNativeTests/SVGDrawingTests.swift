import AppKit
import PencilKit
import XCTest
@testable import NotesNative

final class SVGDrawingTests: XCTestCase {
    func testParsesShapesTransformsAndViewBox() throws {
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><g transform="translate(10 5) scale(2)"><line x1="0" y1="0" x2="10" y2="0" stroke="#ff0000" stroke-width="2"/><rect x="0" y="10" width="5" height="4" fill="none" stroke="blue"/></g></svg>"##.utf8)
        let parsed = try SVGDrawingConverter.parse(svg)

        XCTAssertEqual(parsed.size, DrawingSize(width: 100, height: 50))
        XCTAssertEqual(parsed.strokes.count, 2)
        XCTAssertEqual(parsed.strokes[0], SVGStroke(points: [.init(x: 10, y: 5), .init(x: 30, y: 5)],
                                                     color: .init(red: 1, green: 0, blue: 0), width: 4, closed: false))
        XCTAssertEqual(parsed.strokes[1].points, [.init(x: 10, y: 25), .init(x: 20, y: 25), .init(x: 20, y: 33),
                                                 .init(x: 10, y: 33), .init(x: 10, y: 25)])
        XCTAssertEqual(parsed.strokes[1].color, DrawingColor(red: 0, green: 0, blue: 1))
    }

    func testParsesCurvesArcAndRelativeCommands() throws {
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20"><path d="M0 10 C5 0 10 0 15 10 S25 20 30 10 A5 5 0 0 1 40 10 l-2 2 q-2 2-4 0 t-4 0" fill="none" stroke="black"/></svg>"##.utf8)
        let parsed = try SVGDrawingConverter.parse(svg)

        XCTAssertEqual(parsed.strokes.count, 1)
        XCTAssertEqual(parsed.strokes[0].points.first, DrawingPoint(x: 0, y: 10))
        XCTAssertEqual(parsed.strokes[0].points.last, DrawingPoint(x: 30, y: 12))
        XCTAssertEqual(parsed.strokes[0].points.count, 74)
    }

    func testConvertsSVGToSerializablePencilKitStrokes() throws {
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><polyline points="0,0 5,5 10,0" fill="none" stroke="#336699" stroke-width="3"/></svg>"##.utf8)
        let drawing = try SVGDrawingConverter.drawing(from: svg, options: .init(ink: .monoline, width: 2, blackAndWhite: true))
        XCTAssertEqual(drawing.strokes[0].ink.inkType, .monoline)
        let decoded = try PKDrawing(data: drawing.dataRepresentation())

        XCTAssertEqual(decoded.strokes.count, 1)
        XCTAssertEqual(decoded.strokes[0].ink.inkType, .pen)
        XCTAssertEqual(decoded.strokes[0].ink.color.usingColorSpace(.deviceRGB)?.redComponent, 0)
        XCTAssertEqual(decoded.strokes[0].path.first?.location, CGPoint(x: 0, y: 0))
        XCTAssertEqual(decoded.strokes[0].path.last?.location, CGPoint(x: 10, y: 0))
        XCTAssertEqual(decoded.strokes[0].path.first?.size, CGSize(width: 2, height: 2))
    }

    func testSerializesPencilKitDrawingAsLiteralSVG() {
        let points = [
            PKStrokePoint(location: CGPoint(x: 0, y: 0), timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 3, y: 0), timeOffset: 1, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
        ]
        let stroke = PKStroke(ink: PKInk(.pen, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
                              path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))

        XCTAssertEqual(SVGDrawingConverter.svg(from: PKDrawing(strokes: [stroke])),
                       ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="-1 -1 5 2"><path d="M0 0 L1 0 L2 0 L3 0" fill="none" stroke="#ff0000" stroke-opacity="1" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>"##)
    }

    func testHatchesFilledPolygonWithLiteralSegments() throws {
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><polygon points="0,0 8,0 8,8 0,8" fill="#00ff00" stroke="none"/></svg>"##.utf8)
        let parsed = try SVGDrawingConverter.parse(svg, options: .init(fill: .hatch))

        XCTAssertEqual(parsed.strokes.count, 2)
        XCTAssertEqual(parsed.strokes[1], SVGStroke(points: [.init(x: 0, y: 4), .init(x: 8, y: 4)],
                                                     color: .init(red: 0, green: 1, blue: 0), width: 1, closed: false))
    }

    func testClosesFilledOpenPathOutline() throws {
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><path d="M0 0 L8 0 L8 8" fill="#ff0000" stroke="none"/></svg>"##.utf8)
        let parsed = try SVGDrawingConverter.parse(svg)

        XCTAssertEqual(parsed.strokes, [SVGStroke(points: [.init(x: 0, y: 0), .init(x: 8, y: 0),
                                                                 .init(x: 8, y: 8), .init(x: 0, y: 0)],
                                                        color: .init(red: 1, green: 0, blue: 0), width: 1, closed: true)])
    }
}
