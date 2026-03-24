//
//  ArgentumVaultUITests.swift
//  ArgentumVaultUITests
//
//  Created by Viktor Parshyn on 2026-02-04.
//

import XCTest

final class ArgentumVaultUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testControlCenterDiscoveryDebug() throws {
        let app = XCUIApplication()
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        sleep(1)

        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.01))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(2)

        addDebugArtifacts(from: springboard, named: "ControlCenterOpen")

        if let addControlButton = firstElement(containing: "Add a Control", in: springboard) {
            addControlButton.tap()
            sleep(2)
            addDebugArtifacts(from: springboard, named: "AddControlScreen")
        } else {
            let center = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            center.press(forDuration: 1.0)
            sleep(2)
            addDebugArtifacts(from: springboard, named: "ControlCenterEditMode")

            if let addControlButton = firstElement(containing: "Add a Control", in: springboard) {
                addControlButton.tap()
                sleep(2)
                addDebugArtifacts(from: springboard, named: "AddControlScreen")
            }
        }

        if let searchField = firstElement(containing: "Search Controls", in: springboard) ??
            firstElement(containing: "Search", in: springboard) {
            searchField.tap()
            searchField.typeText("AV New Expense Test")
            sleep(2)
            addDebugArtifacts(from: springboard, named: "AddControlSearchResults")
        }

        let control = springboard.buttons["com.argentumvault.app.controls.new-expense"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Expected AV New Expense Test control to appear in Add a Control results")
    }

    private func addDebugArtifacts(from app: XCUIApplication, named name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-Tree"
        tree.lifetime = .keepAlways
        add(tree)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name)-Screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func firstElement(containing text: String, in app: XCUIApplication) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", text, text)
        let query = app.descendants(matching: .any).matching(predicate)
        let element = query.firstMatch
        return element.exists ? element : nil
    }
}
