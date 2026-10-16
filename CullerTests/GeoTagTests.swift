import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Culler

/// Capture locations read from a file's EXIF GPS block — south/west must come
/// back negative, or pins land on the wrong side of the planet.
final class GeoTagTests: XCTestCase {

    private func writeJPEG(gps: [CFString: Any]?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let gps { props[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSouthWestCoordinatesAreNegative() async throws {
        let url = try writeJPEG(gps: [
            kCGImagePropertyGPSLatitude: 33.8688, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 70.6693, kCGImagePropertyGPSLongitudeRef: "W",
        ])
        let meta = await ThumbnailStore.metadata(for: url)
        let point = try XCTUnwrap(meta.coordinate)
        XCTAssertEqual(point.latitude, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(point.longitude, -70.6693, accuracy: 0.0001)
        XCTAssertEqual(point.displayText, "33.8688° S, 70.6693° W")
    }

    func testNorthEastAndMissingGPS() async throws {
        let tagged = try writeJPEG(gps: [
            kCGImagePropertyGPSLatitude: 48.1374, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 11.5755, kCGImagePropertyGPSLongitudeRef: "E",
        ])
        let meta = await ThumbnailStore.metadata(for: tagged)
        let point = try XCTUnwrap(meta.coordinate)
        XCTAssertEqual(point.latitude, 48.1374, accuracy: 0.0001)
        XCTAssertEqual(point.longitude, 11.5755, accuracy: 0.0001)

        let untagged = try writeJPEG(gps: nil)
        let none = await ThumbnailStore.metadata(for: untagged).coordinate
        XCTAssertNil(none)
    }
}
