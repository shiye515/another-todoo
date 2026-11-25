import AppKit
import SwiftUI

/// 让横向滚动行响应普通鼠标滚轮：命中变体行的纵向滚轮被换算为横向滚动。
/// 轨迹板横向滑动、Shift+滚轮等系统原生横向滚动行为不受影响。
/// 用法：作为背景挂在横向 `ScrollView` 的内容上。
struct HorizontalWheelScrollSupport: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.installMonitorIfNeeded()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitorIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var hostView: NSView?
        private var monitor: Any?

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitorIfNeeded() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        /// 命中横向滚动行且以纵向分量为主的滚轮事件 → 换算为横向滚动并吞掉原事件。
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let hostView,
                  let scrollView = hostView.enclosingScrollView,
                  let hitView = event.window?.contentView?.hitTest(event.locationInWindow),
                  hitView.enclosingScrollView === scrollView,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  event.scrollingDeltaY != 0
            else { return event }

            let clipView = scrollView.contentView
            let visibleWidth = clipView.bounds.width
            let contentWidth = clipView.documentView?.frame.width ?? 0
            guard contentWidth > visibleWidth else { return event }

            var origin = clipView.bounds.origin
            origin.x = Self.targetOffset(
                currentX: origin.x,
                deltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                visibleWidth: visibleWidth,
                contentWidth: contentWidth
            )
            clipView.scroll(to: NSPoint(x: origin.x, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
            return nil
        }

        /// 纵向滚轮位移换算为目标横向偏移（纯函数，便于单元测试）。
        /// 鼠标滚轮按「行」计步，换算为固定点数；轨迹板精度滚动 1:1；结果裁剪到可滚动范围。
        static func targetOffset(
            currentX: CGFloat,
            deltaY: CGFloat,
            hasPreciseDeltas: Bool,
            visibleWidth: CGFloat,
            contentWidth: CGFloat
        ) -> CGFloat {
            guard contentWidth > visibleWidth else { return currentX }
            let scale: CGFloat = hasPreciseDeltas ? 1 : 28
            let unclamped = currentX - deltaY * scale
            return min(max(0, unclamped), contentWidth - visibleWidth)
        }
    }
}
