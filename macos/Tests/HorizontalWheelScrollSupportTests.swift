import XCTest

@testable import TodooCardMacApp

/// 横向滚轮换算测试：纵向滚轮 → 横向偏移的方向、步长与边界裁剪。
final class HorizontalWheelScrollSupportTests: XCTestCase {
    private typealias Support = HorizontalWheelScrollSupport.Coordinator

    func testWheelDownScrollsRight() {
        // 滚轮向下（deltaY < 0）→ 偏移增大，视口向右（露出右侧内容）
        let offset = Support.targetOffset(
            currentX: 100, deltaY: -1, hasPreciseDeltas: false,
            visibleWidth: 400, contentWidth: 800
        )
        XCTAssertEqual(offset, 128)
    }

    func testWheelUpScrollsLeft() {
        let offset = Support.targetOffset(
            currentX: 100, deltaY: 2, hasPreciseDeltas: false,
            visibleWidth: 400, contentWidth: 800
        )
        XCTAssertEqual(offset, 44)
    }

    func testPreciseDeltasMapOneToOne() {
        let offset = Support.targetOffset(
            currentX: 100, deltaY: -13.5, hasPreciseDeltas: true,
            visibleWidth: 400, contentWidth: 800
        )
        XCTAssertEqual(offset, 113.5, accuracy: 0.001)
    }

    func testOffsetClampedToScrollableRange() {
        XCTAssertEqual(
            Support.targetOffset(currentX: 395, deltaY: -10, hasPreciseDeltas: false, visibleWidth: 400, contentWidth: 800),
            400,
            "超出右界应裁剪到 contentWidth - visibleWidth"
        )
        XCTAssertEqual(
            Support.targetOffset(currentX: 5, deltaY: 10, hasPreciseDeltas: false, visibleWidth: 400, contentWidth: 800),
            0,
            "超出左界应裁剪到 0"
        )
    }

    func testNoScrollWhenContentFits() {
        let offset = Support.targetOffset(
            currentX: 0, deltaY: -5, hasPreciseDeltas: false,
            visibleWidth: 400, contentWidth: 300
        )
        XCTAssertEqual(offset, 0, "内容未溢出时不应滚动")
    }
}
