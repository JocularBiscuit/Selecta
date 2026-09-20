import CoreGraphics

#if canImport(UIKit)
import UIKit
/// The platform's native image type — `UIImage` on iOS, `NSImage` on macOS.
/// Shared engine code (thumbnail decoding, PhotoKit access, histograms)
/// works against this instead of either concrete type, so it compiles
/// unchanged on both platforms.
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

extension PlatformImage {
    /// `UIImage(cgImage:)` already exists on iOS; `NSImage` needs an
    /// explicit size. A static factory (rather than an extension initializer
    /// with the same signature as UIImage's own) avoids ambiguity/recursion
    /// with the platform's built-in initializer.
    static func fromCGImage(_ cg: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return PlatformImage(cgImage: cg)
        #elseif canImport(AppKit)
        return PlatformImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        #endif
    }

    /// `UIImage.cgImage` is a stored property; `NSImage` has no equivalent
    /// stored property and must render one on demand.
    var cgImageCompat: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    /// `UIImage.jpegData(compressionQuality:)` has no `NSImage` equivalent —
    /// AppKit encodes via `NSBitmapImageRep` instead.
    func jpegDataCompat(compressionQuality: CGFloat) -> Data? {
        #if canImport(UIKit)
        return jpegData(compressionQuality: compressionQuality)
        #elseif canImport(AppKit)
        guard let cg = cgImageCompat else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
        #endif
    }
}
