import SwiftUI
import UIKit

struct RecordingSlideControl: UIViewRepresentable {
    let value: Double
    let enabled: Bool
    let thumbSize: CGSize
    let thumbTint: Color
    let onBegan: () -> Void
    let onChanged: (Double) -> Void
    let onEnded: (_ value: Double, _ cancelled: Bool) -> Void

    func makeUIView(context: Context) -> RecordingNativeSlider {
        let slider = RecordingNativeSlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.isContinuous = true
        slider.semanticContentAttribute = .forceLeftToRight
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear
        slider.thumbTintColor = UIColor(thumbTint)
        return slider
    }

    func updateUIView(_ slider: RecordingNativeSlider, context: Context) {
        slider.onBegan = onBegan
        slider.onChanged = onChanged
        slider.onEnded = onEnded
        slider.thumbSize = thumbSize
        slider.isEnabled = enabled
        let tint = UIColor(thumbTint)
        if slider.thumbTintColor != tint { slider.thumbTintColor = tint }

        guard !slider.isTracking else { return }
        let target = Float(min(1, max(0, value)))
        if slider.value != target {
            slider.setValue(target, animated: slider.window != nil)
        }
    }
}

final class RecordingNativeSlider: UISlider {
    var thumbSize: CGSize = .zero {
        didSet {
            if oldValue != thumbSize { setNeedsLayout() }
        }
    }
    var onBegan: () -> Void = {}
    var onChanged: (Double) -> Void = { _ in }
    var onEnded: (Double, Bool) -> Void = { _, _ in }
    private var hasActiveTracking = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }

    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let height = super.trackRect(forBounds: bounds).height
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    override func thumbRect(forBounds bounds: CGRect, trackRect rect: CGRect, value: Float) -> CGRect {
        guard thumbSize.width > 0, thumbSize.height > 0 else {
            return super.thumbRect(forBounds: bounds, trackRect: rect, value: value)
        }
        let width = min(thumbSize.width, bounds.width)
        let height = min(thumbSize.height, bounds.height)
        let range = maximumValue - minimumValue
        let progress = range > 0 ? CGFloat(min(1, max(0, (value - minimumValue) / range))) : 0
        return CGRect(
            x: rect.minX + max(0, rect.width - width) * progress,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let thumb = thumbRect(forBounds: bounds, trackRect: trackRect(forBounds: bounds), value: value)
        guard isEnabled, thumb.contains(touch.location(in: self)), super.beginTracking(touch, with: event) else {
            return false
        }
        hasActiveTracking = true
        onBegan()
        onChanged(Double(value))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let shouldNotify = hasActiveTracking
        hasActiveTracking = false
        super.endTracking(touch, with: event)
        // UIKit can complete a slider gesture without a touch; cancellation is reported separately.
        if shouldNotify { onEnded(Double(value), false) }
    }

    override func cancelTracking(with event: UIEvent?) {
        let shouldNotify = hasActiveTracking
        hasActiveTracking = false
        super.cancelTracking(with: event)
        if shouldNotify { onEnded(Double(value), true) }
    }

    @objc private func valueChanged() {
        if hasActiveTracking { onChanged(Double(value)) }
    }
}
