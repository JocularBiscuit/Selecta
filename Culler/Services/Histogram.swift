import SwiftUI

/// RGB histogram, Lightroom-style: three channels rendered additively so
/// overlapping regions blend toward white.
struct HistogramData: Equatable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var peak: Float
}

enum HistogramEngine {
    /// Computes a 256-bin RGB histogram from a small downsampled render.
    /// Cheap enough to run on every loupe image change.
    static func compute(from image: PlatformImage) async -> HistogramData? {
        let cg = image.cgImageCompat
        return await Task.detached(priority: .utility) { () -> HistogramData? in
            guard let cg else { return nil }
            let maxDim: CGFloat = 220
            let scale = min(1, maxDim / CGFloat(max(cg.width, cg.height)))
            let width = max(1, Int(CGFloat(cg.width) * scale))
            let height = max(1, Int(CGFloat(cg.height) * scale))
            guard let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = ctx.data else { return nil }

            var red = [Float](repeating: 0, count: 256)
            var green = red
            var blue = red
            let ptr = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                red[Int(ptr[i])] += 1
                green[Int(ptr[i + 1])] += 1
                blue[Int(ptr[i + 2])] += 1
            }
            // sqrt compression keeps shadows/highlights readable (LR-ish)
            for i in 0..<256 {
                red[i] = red[i].squareRoot()
                green[i] = green[i].squareRoot()
                blue[i] = blue[i].squareRoot()
            }
            let peak = max(red.max() ?? 1, green.max() ?? 1, blue.max() ?? 1, 1)
            return HistogramData(red: red, green: green, blue: blue, peak: peak)
        }.value
    }
}

struct HistogramView: View {
    let data: HistogramData

    var body: some View {
        Canvas { context, size in
            context.blendMode = .plusLighter
            drawChannel(data.red, tint: Color(red: 0.85, green: 0.25, blue: 0.22), in: &context, size: size)
            drawChannel(data.green, tint: Color(red: 0.25, green: 0.8, blue: 0.35), in: &context, size: size)
            drawChannel(data.blue, tint: Color(red: 0.25, green: 0.45, blue: 0.95), in: &context, size: size)
        }
        .background(Color.black.opacity(0.75))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }

    private func drawChannel(_ bins: [Float], tint: Color, in context: inout GraphicsContext, size: CGSize) {
        guard bins.count == 256, data.peak > 0 else { return }
        var path = Path()
        let stepX = size.width / 255
        path.move(to: CGPoint(x: 0, y: size.height))
        for i in 0..<256 {
            let x = CGFloat(i) * stepX
            let y = size.height - CGFloat(bins[i] / data.peak) * size.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(tint.opacity(0.85)))
    }
}
