import XCTest
@testable import Culler

/// Exhaustive tests for the `XMP` sidecar reader/writer.
final class XMPTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    // MARK: - Helpers

    /// Writes `contents` to `name` inside the per-test temp directory.
    @discardableResult
    private func writeFile(_ name: String, contents: String = "x") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeItem(baseName: String = "DSC01234",
                          rawURL: URL? = nil,
                          jpegURL: URL? = nil,
                          videoURL: URL? = nil,
                          rating: Int = 0,
                          label: ColorLabel? = nil) -> CardItem {
        CardItem(id: "card|\(baseName.lowercased())",
                 baseName: baseName,
                 rawURL: rawURL,
                 jpegURL: jpegURL,
                 videoURL: videoURL,
                 rawSize: 0,
                 jpegSize: 0,
                 fileDate: Date(timeIntervalSince1970: 0),
                 rating: rating,
                 flag: .none,
                 label: label)
    }

    // MARK: - packet()

    func testPacketContainsRatingForAllValidValues() {
        for rating in 0...5 {
            let packet = XMP.packet(rating: rating, label: nil)
            XCTAssertTrue(packet.contains("xmp:Rating=\"\(rating)\""),
                          "packet missing xmp:Rating=\"\(rating)\"")
        }
    }

    func testPacketOmitsLabelWhenNil() {
        let packet = XMP.packet(rating: 3, label: nil)
        XCTAssertFalse(packet.contains("xmp:Label"),
                       "packet must not mention xmp:Label when no label is set")
    }

    func testPacketIncludesLabelForEveryColorLabel() {
        for label in ColorLabel.allCases {
            let packet = XMP.packet(rating: 1, label: label)
            XCTAssertTrue(packet.contains("xmp:Label=\"\(label.rawValue)\""),
                          "packet missing xmp:Label=\"\(label.rawValue)\"")
        }
    }

    func testPacketClampsRatingAboveFiveToFive() {
        let packet = XMP.packet(rating: 9, label: nil)
        XCTAssertTrue(packet.contains("xmp:Rating=\"5\""))
        XCTAssertFalse(packet.contains("xmp:Rating=\"9\""))
    }

    func testPacketClampsNegativeRatingToZero() {
        let packet = XMP.packet(rating: -1, label: nil)
        XCTAssertTrue(packet.contains("xmp:Rating=\"0\""))
        XCTAssertFalse(packet.contains("xmp:Rating=\"-1\""))
    }

    func testPacketHasXMPEnvelope() {
        let packet = XMP.packet(rating: 2, label: .green)
        XCTAssertTrue(packet.contains("<?xpacket begin="))
        XCTAssertTrue(packet.contains("<x:xmpmeta"))
        XCTAssertTrue(packet.contains("<rdf:RDF"))
        XCTAssertTrue(packet.contains("xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\""))
        XCTAssertTrue(packet.contains("<?xpacket end=\"w\"?>"))
    }

    // MARK: - Round-trip write(rating:label:nextTo:) + read

    func testRoundTripAllLabelsAndAllRatings() throws {
        var labels: [ColorLabel?] = ColorLabel.allCases
        labels.append(nil)

        for label in labels {
            for rating in 0...5 {
                let name = "EXPORT-\(rating)-\(label?.rawValue ?? "none").JPG"
                let exported = try writeFile(name)

                XCTAssertTrue(XMP.write(rating: rating, label: label,
                                        nextTo: exported, includeExtension: false))

                let sidecar = exported.deletingPathExtension().appendingPathExtension("xmp")
                XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))

                let values = try XCTUnwrap(
                    XMP.read(from: sidecar),
                    "read failed for rating=\(rating) label=\(label?.rawValue ?? "nil")")
                XCTAssertEqual(values.rating, rating,
                               "rating mismatch for label=\(label?.rawValue ?? "nil")")
                XCTAssertEqual(values.label, label,
                               "label mismatch for rating=\(rating)")
            }
        }
    }

    func testRoundTripWithIncludeExtensionTrue() throws {
        let exported = try writeFile("DSC09999.ARW")
        XCTAssertTrue(XMP.write(rating: 4, label: .blue,
                                nextTo: exported, includeExtension: true))

        let sidecar = tempDir.appendingPathComponent("DSC09999.ARW.xmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))

        let values = try XCTUnwrap(XMP.read(from: sidecar))
        XCTAssertEqual(values.rating, 4)
        XCTAssertEqual(values.label, .blue)
    }

    func testWriteForItemCreatesReadableSidecarNextToRAW() throws {
        let raw = try writeFile("DSC01234.ARW")
        let item = makeItem(rawURL: raw, rating: 3, label: .red)

        XCTAssertTrue(XMP.write(for: item, includeExtension: false))

        let sidecar = tempDir.appendingPathComponent("DSC01234.xmp")
        let values = try XCTUnwrap(XMP.read(from: sidecar))
        XCTAssertEqual(values.rating, 3)
        XCTAssertEqual(values.label, .red)
    }

    func testWriteForItemWithNoFilesReturnsFalse() {
        XCTAssertFalse(XMP.write(for: makeItem(), includeExtension: false))
    }

    // MARK: - read(): attribute form

    func testReadParsesAttributeForm() throws {
        let url = try writeFile("attr.xmp", contents: """
            <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""
                  xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                  xmp:Rating="3"
                  xmp:Label="Blue"/>
              </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """)
        let values = try XCTUnwrap(XMP.read(from: url))
        XCTAssertEqual(values.rating, 3)
        XCTAssertEqual(values.label, .blue)
    }

    func testReadParsesAttributeFormWithWhitespaceAroundEquals() throws {
        let url = try writeFile("attr-ws.xmp", contents:
            #"<rdf:Description xmp:Rating = "4" xmp:Label =  "Green"/>"#)
        let values = try XCTUnwrap(XMP.read(from: url))
        XCTAssertEqual(values.rating, 4)
        XCTAssertEqual(values.label, .green)
    }

    // MARK: - read(): Lightroom element form

    func testReadParsesElementForm() throws {
        let url = try writeFile("element.xmp", contents: """
            <rdf:Description rdf:about="">
              <xmp:Rating>3</xmp:Rating>
              <xmp:Label>Purple</xmp:Label>
            </rdf:Description>
            """)
        let values = try XCTUnwrap(XMP.read(from: url))
        XCTAssertEqual(values.rating, 3)
        XCTAssertEqual(values.label, .purple)
    }

    func testReadParsesElementFormWithInnerWhitespace() throws {
        let url = try writeFile("element-ws.xmp", contents: """
            <rdf:Description>
              <xmp:Rating>  2  </xmp:Rating>
              <xmp:Label>
                Yellow
              </xmp:Label>
            </rdf:Description>
            """)
        let values = try XCTUnwrap(XMP.read(from: url))
        XCTAssertEqual(values.rating, 2)
        XCTAssertEqual(values.label, .yellow)
    }

    func testReadParsesMixedAttributeRatingAndElementLabel() throws {
        let url = try writeFile("mixed.xmp", contents: """
            <rdf:Description xmp:Rating="5">
              <xmp:Label>Red</xmp:Label>
            </rdf:Description>
            """)
        let values = try XCTUnwrap(XMP.read(from: url))
        XCTAssertEqual(values.rating, 5)
        XCTAssertEqual(values.label, .red)
    }

    // MARK: - read(): rating clamping

    func testReadClampsAttributeRatingAboveFiveToFive() throws {
        let url = try writeFile("high.xmp", contents:
            #"<rdf:Description xmp:Rating="9"/>"#)
        let values = try XCTUnwrap(XMP.read(from: url))
        XCTAssertEqual(values.rating, 5)
    }

    func testReadClampsNegativeAttributeRatingToZero() throws {
        let url = try writeFile("neg.xmp", contents:
            #"<rdf:Description xmp:Rating="-1"/>"#)
        let values = try XCTUnwrap(XMP.read(from: url))
        XCTAssertEqual(values.rating, 0)
    }

    func testReadClampsNegativeElementRatingToZero() throws {
        let url = try writeFile("neg-element.xmp", contents:
            "<xmp:Rating>-1</xmp:Rating>")
        let values = try XCTUnwrap(XMP.read(from: url))
        XCTAssertEqual(values.rating, 0)
    }

    // MARK: - read(): unknown label

    func testReadUnknownLabelYieldsNilLabelButKeepsRating() throws {
        let url = try writeFile("unknown-label.xmp", contents:
            #"<rdf:Description xmp:Rating="2" xmp:Label="Chartreuse"/>"#)
        let values = try XCTUnwrap(XMP.read(from: url),
                                   "parse must still succeed with an unknown label")
        XCTAssertEqual(values.rating, 2)
        XCTAssertNil(values.label)
    }

    func testReadUnknownLabelAloneStillSucceeds() throws {
        let url = try writeFile("unknown-only.xmp", contents:
            #"<rdf:Description xmp:Label="Mauve"/>"#)
        let values = try XCTUnwrap(XMP.read(from: url))
        XCTAssertNil(values.label)
        XCTAssertEqual(values.rating, 0)
    }

    // MARK: - read(): nil cases

    func testReadReturnsNilForMissingFile() {
        let url = tempDir.appendingPathComponent("does-not-exist.xmp")
        XCTAssertNil(XMP.read(from: url))
    }

    func testReadReturnsNilForFileWithoutXMPFields() throws {
        let url = try writeFile("empty-meta.xmp", contents: """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""/>
              </rdf:RDF>
            </x:xmpmeta>
            """)
        XCTAssertNil(XMP.read(from: url))
    }

    func testReadReturnsNilForNonXMLFile() throws {
        let url = try writeFile("garbage.xmp", contents: "just some plain text")
        XCTAssertNil(XMP.read(from: url))
    }

    // MARK: - sidecarURL()

    func testSidecarURLWithoutExtensionUsesBaseName() {
        let raw = tempDir.appendingPathComponent("DSC01234.ARW")
        let item = makeItem(rawURL: raw)
        let sidecar = XMP.sidecarURL(for: item, includeExtension: false)
        XCTAssertEqual(sidecar?.lastPathComponent, "DSC01234.xmp")
        XCTAssertEqual(sidecar?.deletingLastPathComponent().path, tempDir.path,
                       "sidecar must live next to the anchor file")
    }

    func testSidecarURLWithExtensionKeepsOriginalExtension() {
        let raw = tempDir.appendingPathComponent("DSC01234.ARW")
        let item = makeItem(rawURL: raw)
        let sidecar = XMP.sidecarURL(for: item, includeExtension: true)
        XCTAssertEqual(sidecar?.lastPathComponent, "DSC01234.ARW.xmp")
    }

    func testSidecarURLPrefersRAWOverJPEGAsAnchor() {
        let raw = tempDir.appendingPathComponent("DSC01234.ARW")
        let jpeg = tempDir.appendingPathComponent("DSC01234.JPG")
        let item = makeItem(rawURL: raw, jpegURL: jpeg)
        XCTAssertEqual(XMP.sidecarURL(for: item, includeExtension: true)?.lastPathComponent,
                       "DSC01234.ARW.xmp",
                       "RAW must win over JPEG as the sidecar anchor")
    }

    func testSidecarURLFallsBackToJPEGWhenNoRAW() {
        let jpeg = tempDir.appendingPathComponent("DSC01234.JPG")
        let item = makeItem(jpegURL: jpeg)
        XCTAssertEqual(XMP.sidecarURL(for: item, includeExtension: true)?.lastPathComponent,
                       "DSC01234.JPG.xmp")
    }

    func testSidecarURLFallsBackToVideoWhenNoRAWOrJPEG() {
        let video = tempDir.appendingPathComponent("CLIP0001.MOV")
        let item = makeItem(baseName: "CLIP0001", videoURL: video)
        XCTAssertEqual(XMP.sidecarURL(for: item, includeExtension: false)?.lastPathComponent,
                       "CLIP0001.xmp")
    }

    func testSidecarURLIsNilWhenItemHasNoFiles() {
        XCTAssertNil(XMP.sidecarURL(for: makeItem(), includeExtension: false))
        XCTAssertNil(XMP.sidecarURL(for: makeItem(), includeExtension: true))
    }
}
