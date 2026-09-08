import XCTest
@testable import MonitorCore

final class MenuPresentationTests: XCTestCase {
    func task(_ id: String, _ status: WorkStatus, live: Bool = true) -> TaskState {
        var task = TaskState(id: id, title: id); task.status = status; task.isLive = live; return task
    }
    func testCompletionEdgesAndAcknowledgement() {
        var notifications = CompletionNotifications()
        notifications.update([task("old", .completed), task("a", .working), task("b", .replying)])
        XCTAssertTrue(notifications.unread.isEmpty)
        let completed = [task("old", .completed), task("a", .completed), task("b", .completed)]
        notifications.update(completed); notifications.update(completed)
        XCTAssertEqual(notifications.unread, ["a", "b"])
        notifications.acknowledge("a"); notifications.update(completed)
        XCTAssertEqual(notifications.unread, ["b"])
        notifications.update([task("a", .working), task("b", .completed)])
        notifications.update([task("a", .completed), task("b", .completed)])
        XCTAssertEqual(notifications.unread, ["a", "b"])
    }
    func testOfflineFailedAndRemoval() {
        var notifications = CompletionNotifications()
        notifications.update([task("a", .working), task("b", .working)])
        notifications.update([task("a", .completed, live: false), task("b", .failed)])
        XCTAssertTrue(notifications.unread.isEmpty)
        var incompatible = task("a", .completed); incompatible.connectionIssue = "v12"
        notifications.update([incompatible, task("b", .completed)])
        XCTAssertTrue(notifications.unread.isEmpty)
        notifications.update([task("a", .completed)])
        XCTAssertEqual(notifications.unread, ["a"])
        notifications.update([]); XCTAssertTrue(notifications.unread.isEmpty)
    }
    func testDesktopThemeWhitelistAndBothVariants() {
        let config = """
        [unrelated]
        appearanceTheme = "dark"
        [desktop]
        appearanceTheme = "light" # override system
        [desktop.appearanceLightChromeTheme]
        surface = "#ffffff"
        ink = "#030303"
        accent = "#ff6363"
        [desktop.appearanceLightChromeTheme.fonts]
        ui = "Inter"
        code = '\"Jetbrains Mono\"'
        [desktop.appearanceDarkChromeTheme]
        surface = "#10141c"
        ink = "#bfbdb6"
        accent = "#e6b450"
        """
        let light = DesktopThemeSettings(config: config, systemDark: true)
        XCTAssertFalse(light.dark); XCTAssertEqual(light.surface, "#ffffff")
        XCTAssertEqual(light.ink, "#030303"); XCTAssertEqual(light.accent, "#ff6363")
        XCTAssertEqual(light.uiFont, "Inter"); XCTAssertEqual(light.codeFont, "Jetbrains Mono")
        let dark = DesktopThemeSettings(config: config.replacingOccurrences(of: "appearanceTheme = \"light\"", with: "appearanceTheme = \"dark\""))
        XCTAssertTrue(dark.dark); XCTAssertEqual(dark.surface, "#10141c")
        XCTAssertEqual(dark.accent, "#e6b450")
    }
    func testMalformedSettingsFallbackAndSystem() {
        let config = """
        [desktop]
        appearanceTheme = "system"
        [desktop.appearanceDarkChromeTheme]
        surface = "garbage"
        ink = "#123456" trailing invalid
        accent = "#fff"
        """
        XCTAssertTrue(DesktopThemeSettings(config: config, systemDark: true).dark)
        XCTAssertEqual(DesktopThemeSettings(config: config, systemDark: true).surface, "#000000")
        XCTAssertEqual(DesktopThemeSettings(config: config, systemDark: true).ink, "#ededed")
        XCTAssertEqual(DesktopThemeSettings(config: config, systemDark: true).accent, "#3a83f7")
        XCTAssertFalse(DesktopThemeSettings(config: config).dark)
    }
}
