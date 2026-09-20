import SwiftUI
import UIKit

/// UIScrollView-backed zoomable image: pinch to zoom, double-tap to toggle
/// fit ↔ true 100% (one image pixel per device pixel) for focus checks.
///
/// Progressive-loading aware: when the SAME item's image is swapped from a
/// low-res preview to the full-res decode, the on-screen magnification and
/// visible center are preserved (no reset, no animation). Only a change of
/// `itemID` resets the view to fit.
struct ZoomableImageView: UIViewRepresentable {
    let itemID: String
    let image: UIImage?
    @Binding var isZoomed: Bool
    /// Fires true when a pinch begins, false when it ends — lets the host
    /// suppress its own swipe gestures while the user is zooming.
    var onInteractionChanged: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {
        uiView.onZoomChanged = { zoomedIn in
            DispatchQueue.main.async {
                if isZoomed != zoomedIn { isZoomed = zoomedIn }
            }
        }
        uiView.onInteractionChanged = onInteractionChanged
        uiView.setImage(image, itemID: itemID)
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var currentImage: UIImage?
    private var currentItemID: String?
    private var lastLayoutSize: CGSize = .zero
    /// Full-res swap that arrived mid-pinch; applied when the pinch ends.
    private var pendingImage: UIImage?
    /// The "fit to screen" scale — the resting position when a photo opens
    /// and what double-tap zooms back to. Distinct from `minimumZoomScale`,
    /// which is set well below this so pinching out doesn't hit a hard wall.
    private var fitZoomScale: CGFloat = 1

    var onZoomChanged: ((Bool) -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFill
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Image swaps

    func setImage(_ image: UIImage?, itemID: String?) {
        let itemChanged = itemID != currentItemID
        let imageChanged = image !== currentImage
        guard itemChanged || imageChanged else { return }

        currentItemID = itemID
        currentImage = image
        pendingImage = nil

        guard let image else {
            imageView.image = nil
            imageView.frame = .zero
            contentSize = .zero
            minimumZoomScale = 1
            maximumZoomScale = 1
            zoomScale = 1
            return
        }

        if !itemChanged,
           let oldDisplayed = imageView.image,
           oldDisplayed.size.width > 0, image.size.width > 0,
           bounds.width > 0, bounds.height > 0 {
            // Progressive low-res → full-res swap for the same shot.
            if isZooming || isZoomBouncing {
                // Don't fight an active pinch; swap in when it ends.
                pendingImage = image
            } else {
                replacePreservingView(with: image, oldImage: oldDisplayed)
            }
        } else {
            resetToFit(with: image)
        }
    }

    /// New shot: rebuild content and snap to fit. No zoom carry-over.
    private func resetToFit(with image: UIImage) {
        // Neutral baseline so setting the frame isn't distorted by an old
        // zoom transform.
        minimumZoomScale = 1
        maximumZoomScale = 1
        zoomScale = 1
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        configureZoomScales()
        zoomScale = fitZoomScale
        centerImage()
        contentOffset = clampedOffset(for: contentOffset)
        notifyZoomState()
    }

    /// Same shot, sharper pixels: keep the on-screen magnification and the
    /// visible center. Runs without animation — the swap must be invisible
    /// apart from added sharpness.
    private func replacePreservingView(with newImage: UIImage, oldImage: UIImage) {
        let oldZoom = zoomScale
        let normalizedCenter = CGPoint(
            x: contentSize.width > 0
                ? (contentOffset.x + bounds.width / 2) / contentSize.width : 0.5,
            y: contentSize.height > 0
                ? (contentOffset.y + bounds.height / 2) / contentSize.height : 0.5
        )
        let ratio = newImage.size.width / oldImage.size.width
        guard ratio > 0 else {
            resetToFit(with: newImage)
            return
        }

        // Rebuild content at a zoom-1 baseline (no transform on the image view).
        minimumZoomScale = 1
        maximumZoomScale = 1
        zoomScale = 1
        imageView.image = newImage
        imageView.frame = CGRect(origin: .zero, size: newImage.size)
        contentSize = newImage.size

        // Recompute min/max for the new pixel size, then map the old zoom so
        // the visual magnification is unchanged: newZoom = oldZoom / ratio.
        configureZoomScales()
        zoomScale = min(max(oldZoom / ratio, minimumZoomScale), maximumZoomScale)
        centerImage()

        // Restore the visible center in normalized content coordinates.
        let proposed = CGPoint(
            x: normalizedCenter.x * contentSize.width - bounds.width / 2,
            y: normalizedCenter.y * contentSize.height - bounds.height / 2
        )
        contentOffset = clampedOffset(for: proposed)
        notifyZoomState()
    }

    // MARK: Layout & scales

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            rebuildScalesForNewBounds()
        }
        centerImage()
    }

    /// First layout and rotation: recompute fit for the new bounds. If the
    /// user was at fit, stay at fit; otherwise clamp the current zoom.
    private func rebuildScalesForNewBounds() {
        guard currentImage != nil else { return }
        let oldFit = fitZoomScale
        let wasAtFit = abs(zoomScale - oldFit) < max(oldFit * 0.02, 0.001)
        configureZoomScales()
        if wasAtFit {
            zoomScale = fitZoomScale
        } else {
            zoomScale = min(max(zoomScale, minimumZoomScale), maximumZoomScale)
        }
        centerImage()
        contentOffset = clampedOffset(for: contentOffset)
        notifyZoomState()
    }

    private func configureZoomScales() {
        guard let image = currentImage, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        fitZoomScale = fit
        // Real pinch-out headroom below fit: hitting a hard wall exactly at
        // fit felt abrupt and made the gesture feel unresponsive. This also
        // lets a photo be viewed smaller than the screen against its
        // surroundings. bouncesZoom still gives a soft edge past this.
        minimumZoomScale = max(fit * 0.1, 0.02)
        maximumZoomScale = max(1.0, fit * 6)
    }

    private func centerImage() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    private func clampedOffset(for proposed: CGPoint) -> CGPoint {
        let minX = -contentInset.left
        let minY = -contentInset.top
        let maxX = max(minX, contentSize.width - bounds.width + contentInset.right)
        let maxY = max(minY, contentSize.height - bounds.height + contentInset.bottom)
        return CGPoint(
            x: min(max(proposed.x, minX), maxX),
            y: min(max(proposed.y, minY), maxY)
        )
    }

    private func notifyZoomState() {
        // "Zoomed" means away from the resting fit scale in either
        // direction — zoomed in for detail, or pinched out past fit — so
        // the host suppresses chrome/swipe gestures either way.
        onZoomChanged?(abs(zoomScale - fitZoomScale) > fitZoomScale * 0.01)
    }

    // MARK: Double-tap

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard currentImage != nil else { return }
        if zoomScale > fitZoomScale * 1.01 {
            setZoomScale(fitZoomScale, animated: true)
        } else {
            // True 100%: one image pixel per device pixel. Floored at fit
            // (not the extended pinch-out minimum) so the double-tap
            // shortcut always zooms IN, never out past where it started.
            let target = min(maximumZoomScale, max(fitZoomScale, 1.0 / UIScreen.main.scale))
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        notifyZoomState()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        onInteractionChanged?(true)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onInteractionChanged?(false)
        if let pending = pendingImage {
            pendingImage = nil
            if let old = imageView.image, old.size.width > 0, pending.size.width > 0 {
                replacePreservingView(with: pending, oldImage: old)
            } else {
                resetToFit(with: pending)
            }
        }
    }
}
