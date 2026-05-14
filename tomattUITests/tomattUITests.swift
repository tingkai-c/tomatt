import XCTest

final class tomattUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        let launched = app.wait(for: .runningForeground, timeout: 5)
            || app.wait(for: .runningBackground, timeout: 5)
            || app.state == .runningForeground
            || app.state == .runningBackground
        XCTAssertTrue(launched, "tomatt should launch without crashing")
        app.terminate()
    }
}
