// Generates a fake SD card ("TestCard") for exercising Culler without real
// hardware: labeled JPEGs with staggered EXIF capture times, fake RAW
// siblings (JPEG bytes renamed — ImageIO sniffs content, so previews work),
// Sony + Nikon naming, a pre-existing XMP sidecar, and a junk video file.
//
// Usage: swift make-test-card.swift /path/to/output/TestCard
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let outRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "TestCard")

let fm = FileManager.default
try? fm.removeItem(at: outRoot)

func makeJPEG(to url: URL, title: String, hue: CGFloat, exifDate: String) {
    let width = 800, height = 600
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Background: hue-derived color with a darker band for contrast
    func hsv(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> CGColor {
        let i = Int(h * 6) % 6; let f = h * 6 - CGFloat(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let rgb: [CGFloat]
        switch i { case 0: rgb = [v, t, p]; case 1: rgb = [q, v, p]; case 2: rgb = [p, v, t]
                   case 3: rgb = [p, q, v]; case 4: rgb = [t, p, v]; default: rgb = [v, p, q] }
        return CGColor(colorSpace: space, components: [rgb[0], rgb[1], rgb[2], 1])!
    }
    ctx.setFillColor(hsv(hue, 0.65, 0.85))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(hsv(hue, 0.8, 0.45))
    ctx.fill(CGRect(x: 0, y: 220, width: width, height: 160))

    // Filename label, big and centered
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(colorSpace: space, components: [1, 1, 1, 1])!
    ]
    let line = CTLineCreateWithAttributedString(
        CFAttributedStringCreate(nil, title as CFString, attrs as CFDictionary))
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: 270)
    CTLineDraw(line, ctx)

    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.85,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate]
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

struct Shot { let base: String; let raw: String?; let jpeg: Bool }

// Sony folder: pairs, RAW-only, JPEG-only, lowercase mix
let sonyDir = outRoot.appendingPathComponent("DCIM/100MSDCF")
try! fm.createDirectory(at: sonyDir, withIntermediateDirectories: true)
let sonyShots: [Shot] = (1...8).map { Shot(base: String(format: "DSC%05d", $0), raw: "ARW", jpeg: true) }
    + [Shot(base: "DSC00009", raw: "ARW", jpeg: false),   // RAW only
       Shot(base: "DSC00010", raw: nil, jpeg: true)]      // JPEG only

// Nikon folder
let nikonDir = outRoot.appendingPathComponent("DCIM/101NIKON")
try! fm.createDirectory(at: nikonDir, withIntermediateDirectories: true)
let nikonShots: [Shot] = [
    Shot(base: "DSC_0001", raw: "NEF", jpeg: true),
    Shot(base: "DSC_0002", raw: "NEF", jpeg: true),
    Shot(base: "_DSC0003", raw: "NEF", jpeg: false),      // RAW only
    Shot(base: "DSC_0004", raw: "NEF", jpeg: true),
]

var index = 0
func emit(_ shots: [Shot], into dir: URL) {
    for shot in shots {
        index += 1
        let day = 5 + index / 12, hour = 9 + index % 12
        let exif = String(format: "2026:07:%02d %02d:%02d:00", day, hour, (index * 7) % 60)
        let jpegURL = dir.appendingPathComponent("\(shot.base).JPG")
        makeJPEG(to: jpegURL, title: shot.base, hue: CGFloat(index % 12) / 12.0, exifDate: exif)
        if let rawExt = shot.raw {
            try! fm.copyItem(at: jpegURL, to: dir.appendingPathComponent("\(shot.base).\(rawExt)"))
        }
        if !shot.jpeg { try! fm.removeItem(at: jpegURL) }
    }
}
emit(sonyShots, into: sonyDir)
emit(nikonShots, into: nikonDir)

// Lowercase-extension pair (pairing must be case-insensitive)
index += 1
let lcJpeg = sonyDir.appendingPathComponent("dsc00011.jpg")
makeJPEG(to: lcJpeg, title: "DSC00011", hue: 0.08, exifDate: "2026:07:06 18:30:00")
try! fm.copyItem(at: lcJpeg, to: sonyDir.appendingPathComponent("DSC00011.arw"))

// Pre-existing sidecar: DSC00001 should appear with ★3 + Red on first scan
let sidecar = """
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
      xmp:Rating="3" xmp:Label="Red"/>
  </rdf:RDF>
</x:xmpmeta>
"""
try! sidecar.write(to: sonyDir.appendingPathComponent("DSC00001.xmp"), atomically: true, encoding: .utf8)

// Junk video file (badge only; never decoded)
try! Data(repeating: 0, count: 4096).write(to: sonyDir.appendingPathComponent("DSC00012.MP4"))

// Noise that must be ignored
try! "noise".write(to: sonyDir.appendingPathComponent("STATUS.DAT"), atomically: true, encoding: .utf8)

print("TestCard written to \(outRoot.path)")
