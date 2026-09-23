import XCTest

/// The Share sheet and the Join Team sheet without a server (COLLAB-013, SEC-003).  A UI test
/// launch is signed out, which the app treats as offline: the sheets open, explain that they
/// need a connection, and change nothing.  The online flows (invite, roles, links, requests,
/// transfer, team settings) run against the compose stack (TEST-002's collaboration harness).
final class SharingUITests: XCTestCase {
    @MainActor
    func testFileShareOfflineExplainsThatSharingNeedsAConnection() {
        let ui = WireTunerUI.launch()
        ui.chooseMenuItem(command: "file.share", in: "File")
        let sheet = ui.element("share-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "File > Share… opens the Share sheet")
        XCTAssertTrue(ui.element("share.offline").exists, "offline, the sheet says why nothing can be shared")
        XCTAssertFalse(ui.element("share.invite.send").exists && ui.element("share.invite.send").isEnabled)
        ui.element("share.done").click()
        XCTAssertFalse(sheet.waitForExistence(timeout: 1))
    }

    @MainActor
    func testTheToolbarShareButtonOpensTheSameSheet() {
        let ui = WireTunerUI.launch()
        let button = ui.app.toolbars.buttons["Share"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(ui.element("share-sheet").waitForExistence(timeout: 5))
        ui.element("share.done").click()
    }

    @MainActor
    func testJoinTeamChecksThePastedLinkAndNeedsAConnection() {
        let ui = WireTunerUI.launch()
        ui.chooseMenu(["Window", "Library"])
        let join = ui.element("library.joinTeam")
        XCTAssertTrue(join.waitForExistence(timeout: 5))
        join.click()
        let field = ui.element("join.link")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("not a link")
        XCTAssertTrue(ui.element("join.problem").waitForExistence(timeout: 2))
        XCTAssertFalse(ui.element("join.join").isEnabled)
        field.typeKey("a", modifierFlags: .command)
        field.typeText("wiretuner://invite/AbCdEfGhIjKlMnOpQrStUv-_0123456789")
        XCTAssertTrue(ui.element("join.join").isEnabled)
        ui.element("join.join").click()
        XCTAssertTrue(ui.element("join.offline").waitForExistence(timeout: 5), "signed out reads as offline")
        ui.element("join.done").click()
    }
}
