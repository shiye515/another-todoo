import AppKit
import SwiftUI

struct CropCanvasView: NSViewRepresentable {
    let image: NSImage?
    let configuration: ImageEditConfiguration
    @Binding var isInteracting: Bool
    let onConfigurationChange: (ImageEditConfiguration) -> Void

    func makeNSView(context: Context) -> CropCanvasNSView {
        let view = CropCanvasNSView()
        view.onConfigurationChange = onConfigurationChange
        view.onInteractionChange = { interacting in
            DispatchQueue.main.async {
                isInteracting = interacting
            }
        }
        view.image = image
        view.configuration = configuration
        return view
    }

    func updateNSView(_ nsView: CropCanvasNSView, context: Context) {
        nsView.image = image
        nsView.configuration = configuration
        nsView.isInteracting = isInteracting
        nsView.needsDisplay = true
    }
}

final class CropCanvasNSView: NSView {
    var image: NSImage?
    var configuration = ImageEditConfiguration.todocCard528x792
    var isInteracting = false
    var onConfigurationChange: ((ImageEditConfiguration) -> Void)?
    var onInteractionChange: ((Bool) -> Void)?

    private var dragStartLocation: NSPoint?
    private var dragStartConfiguration: ImageEditConfiguration?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let previewRect = fixedPreviewRect(in: bounds)
        let cropRect = fixedCropRect(in: previewRect)
        guard let image else {
            let message = "选择图片后开始取景"
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
            let size = message.size(withAttributes: attributes)
            message.draw(at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            ), withAttributes: attributes)
            return
        }

        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }

        let containScale = min(
            cropRect.width / sourceSize.width,
            cropRect.height / sourceSize.height
        )
        let scale = containScale * configuration.zoom
        let renderedWidth = sourceSize.width * scale
        let renderedHeight = sourceSize.height * scale

        let allowedX = max(0, (renderedWidth - previewRect.width) / 2)
        let allowedY = max(0, (renderedHeight - previewRect.height) / 2)
        let centerX = previewRect.midX + (configuration.horizontalOffset - 0.5) * allowedX * 2
        let centerY = previewRect.midY + (configuration.verticalOffset - 0.5) * allowedY * 2

        let imageRect = NSRect(
            x: centerX - renderedWidth / 2,
            y: centerY - renderedHeight / 2,
            width: renderedWidth,
            height: renderedHeight
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: previewRect).addClip()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.58).setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, cropRect.minY - bounds.minY)).fill()
        NSRect(x: bounds.minX, y: cropRect.maxY, width: bounds.width, height: max(0, bounds.maxY - cropRect.maxY)).fill()
        NSRect(x: bounds.minX, y: cropRect.minY, width: max(0, cropRect.minX - bounds.minX), height: cropRect.height).fill()
        NSRect(x: cropRect.maxX, y: cropRect.minY, width: max(0, bounds.maxX - cropRect.maxX), height: cropRect.height).fill()

        NSColor.white.withAlphaComponent(isInteracting ? 0.95 : 0.75).setStroke()
        let border = NSBezierPath(rect: cropRect)
        border.lineWidth = isInteracting ? 2 : 1
        border.stroke()

        if isInteracting {
            NSColor.white.withAlphaComponent(0.68).setStroke()
            for index in 1...2 {
                let pathVertical = NSBezierPath()
                pathVertical.move(
                    to: NSPoint(
                        x: cropRect.minX + cropRect.width * CGFloat(index) / 3,
                        y: cropRect.minY
                    )
                )
                pathVertical.line(
                    to: NSPoint(
                        x: cropRect.minX + cropRect.width * CGFloat(index) / 3,
                        y: cropRect.maxY
                    )
                )
                pathVertical.lineWidth = 1
                pathVertical.stroke()

                let pathHorizontal = NSBezierPath()
                pathHorizontal.move(
                    to: NSPoint(
                        x: cropRect.minX,
                        y: cropRect.minY + cropRect.height * CGFloat(index) / 3
                    )
                )
                pathHorizontal.line(
                    to: NSPoint(
                        x: cropRect.maxX,
                        y: cropRect.minY + cropRect.height * CGFloat(index) / 3
                    )
                )
                pathHorizontal.lineWidth = 1
                pathHorizontal.stroke()
            }
        }
    }

    private func fixedPreviewRect(in canvasBounds: NSRect) -> NSRect {
        let side = min(canvasBounds.width, canvasBounds.height)
        return NSRect(
            x: canvasBounds.midX - side / 2,
            y: canvasBounds.midY - side / 2,
            width: side,
            height: side
        )
    }

    private func fixedCropRect(in previewRect: NSRect) -> NSRect {
        let height = previewRect.height * 0.80
        let width = height * 2 / 3
        return NSRect(
            x: previewRect.midX - width / 2,
            y: previewRect.midY - height / 2,
            width: width,
            height: height
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard image != nil else { return }
        dragStartLocation = convert(event.locationInWindow, from: nil)
        dragStartConfiguration = configuration
        isInteracting = true
        onInteractionChange?(true)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartLocation,
              var startConfiguration = dragStartConfiguration,
              let image else { return }

        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x
        let dy = current.y - start.y
        let previewRect = fixedPreviewRect(in: bounds)
        let cropRect = fixedCropRect(in: previewRect)
        let containScale = min(
            cropRect.width / image.size.width,
            cropRect.height / image.size.height
        )
        let scale = containScale * configuration.zoom
        let renderedWidth = image.size.width * scale
        let renderedHeight = image.size.height * scale
        let allowedX = max(0, (renderedWidth - previewRect.width) / 2)
        let allowedY = max(0, (renderedHeight - previewRect.height) / 2)

        if allowedX > 0 {
            startConfiguration.horizontalOffset += dx / (allowedX * 2)
        }
        if allowedY > 0 {
            startConfiguration.verticalOffset += dy / (allowedY * 2)
        }

        startConfiguration.horizontalOffset = min(1, max(0, startConfiguration.horizontalOffset))
        startConfiguration.verticalOffset = min(1, max(0, startConfiguration.verticalOffset))
        configuration = startConfiguration
        onConfigurationChange?(startConfiguration)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocation = nil
        dragStartConfiguration = nil
        isInteracting = false
        onInteractionChange?(false)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard image != nil else { return }
        isInteracting = true
        onInteractionChange?(true)

        var updated = configuration
        updated.zoom = min(3, max(1, updated.zoom * (1 + event.magnification)))
        configuration = updated
        onConfigurationChange?(updated)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard image != nil else { return }
        isInteracting = true
        onInteractionChange?(true)

        var updated = configuration
        let delta = event.deltaY != 0 ? event.deltaY : event.deltaX
        updated.zoom = min(3, max(1, updated.zoom + delta * 0.004))
        configuration = updated
        onConfigurationChange?(updated)
        needsDisplay = true

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isInteracting = false
            self.onInteractionChange?(false)
            self.needsDisplay = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180), execute: workItem)
    }
}
