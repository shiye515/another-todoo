import UIKit
import XCTest

/// iOS UI 测试：冒烟 + 核心能力端到端（添加/裁剪入库 → 列表 → 详情 → 选中变体 → 发送入口 → 删除）。
/// 每个用例启动前清空图片库（-UITestResetLibrary），保证相互独立。
final class TodooCardIOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 冒烟

    func testLaunchShowsImageLibraryEmptyStateAndAddEntry() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestResetLibrary"]
        app.launch()

        XCTAssertTrue(app.staticTexts["图片库为空"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["添加图片"].waitForExistence(timeout: 5))
    }

    func testDeviceTabShowsBluetoothStateAndScanControls() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestResetLibrary"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["设备"].waitForExistence(timeout: 10))
        app.tabBars.buttons["设备"].tap()

        XCTAssertTrue(app.staticTexts["蓝牙设备"].waitForExistence(timeout: 5))
        // 模拟器无蓝牙硬件：状态行提示不可用（能力在真机可用）
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '蓝牙'")
        ).count >= 2)
    }

    // MARK: - 端到端：添加 → 裁剪 → 详情 → 选中 → 发送入口 → 删除

    func testAddCropSelectSendAndDeleteFlow() throws {
        let fixtureURL = try Self.makeFixtureImage()
        let app = XCUIApplication()
        app.launchArguments += ["-UITestResetLibrary", "-UITestSeedAddImage", fixtureURL.path]
        app.launch()

        // 1. 裁剪页自动打开（添加队列）
        XCTAssertTrue(app.navigationBars["旋转与裁剪"].waitForExistence(timeout: 15))

        // 2. 确认裁剪 → 入库（成品 + 全部变体量化图）
        app.buttons["确认裁剪"].firstMatch.tap()

        // 3. 列表出现条目（量化缩略图 + 名称 + 日期）
        XCTAssertTrue(app.staticTexts["fixture"].waitForExistence(timeout: 30))

        // 4. 进入详情：成品图卡 + 变体卡（首批可见两个）
        app.staticTexts["fixture"].tap()
        XCTAssertTrue(app.staticTexts["原图（裁剪成品）"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["528×792 · 仅保留裁剪成品"].exists)
        XCTAssertTrue(app.staticTexts["标准量化"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Floyd–Steinberg"].exists)

        // 5. 未选中：发送按钮禁用 + 提示
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH '尚未选择量化版本'")
        ).firstMatch.waitForExistence(timeout: 5))
        let sendButton = app.buttons["发送到设备"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        XCTAssertFalse(sendButton.isEnabled, "未选中变体时发送按钮应禁用")

        // 6. 点击「标准量化」卡片选中 → 底部显示选中信息，发送按钮可用
        app.staticTexts["标准量化"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH '当前选择：标准量化'")
        ).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(sendButton.isEnabled)

        // 7. 未设默认设备时点击发送 → 走发送接线并给出提示（真机上会进入蓝牙传输）
        sendButton.tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '默认设备 ID 无效'")
        ).firstMatch.waitForExistence(timeout: 5))

        // 8. 单变体「重新生成」可用且不崩溃
        app.buttons["重新生成 标准量化"].tap()

        // 9. 横向滚动变体行 → 后续变体卡出现（清单驱动、横向滚动）
        let variantsRow = app.scrollViews["variantsRow"]
        XCTAssertTrue(variantsRow.waitForExistence(timeout: 5))
        variantsRow.swipeLeft()
        XCTAssertTrue(app.staticTexts["Atkinson"].waitForExistence(timeout: 5), "缺少变体卡 Atkinson")
        XCTAssertTrue(app.staticTexts["Ostromoukhov"].waitForExistence(timeout: 5), "缺少变体卡 Ostromoukhov")

        // 10. 回列表（显式点返回并等详情页消失），删除条目（滑动删除；不生效则走长按菜单）→ 空态
        let backButton = app.buttons["BackButton"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "未找到返回按钮")
        backButton.tap()
        let detailGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["原图（裁剪成品）"].firstMatch
        )
        XCTAssertEqual(XCTWaiter().wait(for: [detailGone], timeout: 10), .completed, "未返回图片列表")

        let row = app.staticTexts["fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // 长按条目 → 上下文菜单 → 删除条目（iOS 26 上下文菜单动作以按钮形式暴露）
        row.press(forDuration: 1.5)
        var deleteItem = app.buttons["删除条目"].firstMatch
        if !deleteItem.waitForExistence(timeout: 5) {
            deleteItem = app.menuItems["删除条目"].firstMatch
        }
        XCTAssertTrue(deleteItem.exists, "未找到删除菜单项")
        deleteItem.tap()
        XCTAssertTrue(app.staticTexts["图片库为空"].waitForExistence(timeout: 10))
    }

    // MARK: - 工具

    /// 生成 600×900 测试图片（蓝底黄块红块），写入临时目录供测试导入。
    private static func makeFixtureImage() throws -> URL {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 120, y: 150, width: 240, height: 240))
            UIColor.red.setFill()
            context.fill(CGRect(x: 200, y: 520, width: 200, height: 160))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.png")
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: url)
        return url
    }
}
