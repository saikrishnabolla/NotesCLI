import Foundation
import Testing
@testable import NotesDiagrams

@Test func outputSizeUsesRequestedWidthAndScale() throws {
    let size = try DiagramGeometry.outputPixelSize(
        contentWidth: 1440,
        contentHeight: 900,
        displayWidth: 700,
        scale: 2
    )

    #expect(size.width == 1400)
    #expect(size.height == 875)
}

@Test func outputSizeRoundsHeightToNearestPixel() throws {
    let size = try DiagramGeometry.outputPixelSize(
        contentWidth: 1024,
        contentHeight: 683,
        displayWidth: 700,
        scale: 3
    )

    #expect(size.width == 2100)
    #expect(size.height == 1401)
}

@Test func cropRectRoundsOutwardAndClampsToCanvas() throws {
    let rect = try DiagramGeometry.cropRect(
        left: 12.4,
        top: 20.2,
        right: 1190.1,
        bottom: 640.7,
        canvasWidth: 1200,
        canvasHeight: 660,
        padding: 2
    )

    #expect(rect.x == 10)
    #expect(rect.y == 18)
    #expect(rect.width == 1183)
    #expect(rect.height == 625)
}

@Test func pdfTransformUpscalesPageToThreeXBitmap() throws {
    let transform = try DiagramGeometry.pdfTransform(
        pageWidth: 1200,
        pageHeight: 800,
        pixelWidth: 2100,
        pixelHeight: 1400
    )

    #expect(transform.scale == 1.75)
    #expect(transform.x == 0)
    #expect(transform.y == 0)
}

@Test func pngMetadataRoundTripsLiteralSource() throws {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    let source = Data("<svg viewBox=\"0 0 20 10\"><text>Research → Notes</text></svg>".utf8)
    let embedded = try DiagramSourceMetadata.embed(
        source: source,
        filename: "research.svg",
        mediaType: "image/svg+xml",
        in: png
    )

    let extracted = try DiagramSourceMetadata.extract(from: embedded)
    let restored = try #require(extracted)
    #expect(restored.data == source)
    #expect(restored.filename == "research.svg")
    #expect(restored.mediaType == "image/svg+xml")
    #expect(embedded.starts(with: Data([137, 80, 78, 71, 13, 10, 26, 10])))
}

@Test func renderOptionsRejectUnsupportedScale() {
    #expect(throws: DiagramError.self) {
        try DiagramRenderOptions(width: 700, scale: 4, background: .auto, dark: false)
    }
}

@Test func renderOptionsRejectNonPositiveWidth() {
    #expect(throws: DiagramError.self) {
        try DiagramRenderOptions(width: 0, scale: 2, background: .white, dark: false)
    }
}

@Test func drawingSourceRemovesDefinitionsAndUnsupportedPaintServers() throws {
    let source = Data(#"<svg><defs><pattern id="dots"><circle r="1"/></pattern></defs><rect fill="url(#dots)" stroke='url(#line)'/></svg>"#.utf8)
    let compatible = try DiagramDrawingSource.paperCompatibleSVG(source)

    #expect(String(decoding: compatible, as: UTF8.self) == #"<svg><rect fill="none" stroke="none"/></svg>"#)
}
