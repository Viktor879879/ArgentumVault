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

    @MainActor
    func testNewTransactionAmountFieldSavesCommaDecimalAsTenPointFiftyFive() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        openAddTransaction(in: app)
        selectWalletAndCategory(in: app)

        let amountField = amountField(in: app)
        typeAmountCharacterByCharacter("10,55", into: amountField)
        XCTAssertEqual(amountField.value as? String, "10,55")
        XCTAssertTrue(app.staticTexts["RAW: 10,55"].waitForExistence(timeout: 2))

        saveAddTransaction(in: app)

        XCTAssertTrue(app.staticTexts["-10.55 SEK"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["SAVE_RAW=10,55"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["SAVE_NORMALIZED=10.55"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["SAVE_DECIMAL=10.55"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["-1,055 SEK"].exists)
        XCTAssertFalse(app.staticTexts["-1055 SEK"].exists)
    }

    @MainActor
    func testNewTransactionAmountFieldSavesDotDecimalAsTenPointFiftyFive() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        openAddTransaction(in: app)
        selectWalletAndCategory(in: app)

        let amountField = amountField(in: app)
        typeAmountCharacterByCharacter("10.55", into: amountField)
        XCTAssertEqual(amountField.value as? String, "10.55")
        XCTAssertTrue(app.staticTexts["RAW: 10.55"].waitForExistence(timeout: 2))

        saveAddTransaction(in: app)

        XCTAssertTrue(app.staticTexts["-10.55 SEK"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["SAVE_RAW=10.55"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["SAVE_NORMALIZED=10.55"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["SAVE_DECIMAL=10.55"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["-1,055 SEK"].exists)
        XCTAssertFalse(app.staticTexts["-1055 SEK"].exists)
    }

    @MainActor
    func testNewTransactionAmountFieldSavesCommaDecimalAsZeroPointNinetyNine() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        openAddTransaction(in: app)
        selectWalletAndCategory(in: app)

        let amountField = amountField(in: app)
        typeAmountCharacterByCharacter("0,99", into: amountField)
        XCTAssertEqual(amountField.value as? String, "0,99")
        XCTAssertTrue(app.staticTexts["RAW: 0,99"].waitForExistence(timeout: 2))

        saveAddTransaction(in: app)

        XCTAssertTrue(app.staticTexts["-0.99 SEK"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["SAVE_RAW=0,99"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["SAVE_NORMALIZED=0.99"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["SAVE_DECIMAL=0.99"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["-99 SEK"].exists)
    }

    @MainActor
    func testAddTransactionAcceptsCommaDecimalSeparator() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        enterAddTransactionAmount("15,88", in: app)
        saveAddTransaction(in: app)
        XCTAssertTrue(app.staticTexts["-15.88 SEK"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAddTransactionPreservesExactTypedAmountWhileEditing() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        openAddTransaction(in: app)
        assertRuntimeDebugPanel(path: "AddTransactionView/RawAmountTextField", in: app)

        let amountField = amountField(in: app)
        typeAmountCharacterByCharacter("1000,25", into: amountField)

        let fieldValue = amountField.value as? String
        XCTAssertEqual(fieldValue, "1000,25")
        XCTAssertNotEqual(fieldValue, "1,000.25")
        XCTAssertNotEqual(fieldValue, "1 000,25")
    }

    @MainActor
    func testAddTransactionAcceptsCommaDecimalSeparator_10_55() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        enterAddTransactionAmount("10,55", in: app)
        saveAddTransaction(in: app)

        XCTAssertTrue(app.staticTexts["-10.55 SEK"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAddTransactionAcceptsCommaDecimalSeparator_0_99() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        enterAddTransactionAmount("0,99", in: app)
        saveAddTransaction(in: app)

        XCTAssertTrue(app.staticTexts["-0.99 SEK"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAddTransactionShowsRuntimeMarkerForAmountField() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        openAddTransaction(in: app)
        assertRuntimeDebugPanel(path: "AddTransactionView/RawAmountTextField", in: app)
        assertInFieldRuntimeMarker("AT-AMOUNT", in: app)
    }

    @MainActor
    func testAddTransactionHistoryShowsSavedRuntimeTrace() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        enterAddTransactionAmount("10,55", in: app)
        saveAddTransaction(in: app)

        let historyTrace = app.staticTexts["money_runtime_debug.history"]
        XCTAssertTrue(historyTrace.waitForExistence(timeout: 10))
        XCTAssertTrue(historyTrace.label.contains("MI-RUNTIME-TRACE-1"))
        XCTAssertTrue(historyTrace.label.contains("save=10,55"))
        XCTAssertTrue(historyTrace.label.contains("parsed=10.55"))
        XCTAssertTrue(historyTrace.label.contains("stored=10.55"))
    }

    @MainActor
    func testAddTransactionAcceptsDotDecimalSeparator_10_55() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        enterAddTransactionAmount("10.55", in: app)
        saveAddTransaction(in: app)

        XCTAssertTrue(app.staticTexts["-10.55 SEK"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAddTransactionAcceptsDotDecimalSeparator_0_99() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        enterAddTransactionAmount("0.99", in: app)
        saveAddTransaction(in: app)

        XCTAssertTrue(app.staticTexts["-0.99 SEK"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAddTransactionAccessoryProvidesDotKey() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        openAddTransaction(in: app)
        selectWalletAndCategory(in: app)

        let amountField = amountField(in: app)
        amountField.typeText("10")
        tapAccessoryButton("raw_amount_field.insert_dot", in: app)
        amountField.typeText("55")

        XCTAssertEqual(amountField.value as? String, "10.55")

        saveAddTransaction(in: app)
        XCTAssertTrue(app.staticTexts["-10.55 SEK"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testEditTransactionUsesInFieldRuntimeMarker() throws {
        let app = configuredAppForMoneyInputTrace()
        app.launch()

        enterAddTransactionAmount("10,55", in: app)
        saveAddTransaction(in: app)

        let savedRow = app.staticTexts["-10.55 SEK"]
        XCTAssertTrue(savedRow.waitForExistence(timeout: 10))
        savedRow.tap()

        let amountField = amountField(in: app)
        XCTAssertEqual(amountField.value as? String, "10.55")
        assertInFieldRuntimeMarker("AT-AMOUNT", in: app)
        assertRuntimeDebugPanel(path: "AddTransactionView/RawAmountTextField", in: app)
    }

    private func configuredAppForMoneyInputTrace() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(sv)",
            "-AppleLocale", "sv_SE",
            "-debugResetFirstLaunchOnce_v5", "NO",
            "-didCompleteInitialSetup_v1", "YES",
            "-didShowOnboarding", "YES",
            "-forceShowOnboardingOnce_v4", "NO",
            "-didSeedDefaultCategories_v1", "NO",
            "-baseCurrencyCode", "SEK",
            "-appCountryCode", "SE",
            "-appLanguageCode", "en",
            "-emailUserID", "ui-money-trace",
            "-emailUserEmail", "ui-money-trace@example.com",
            "-authMethod", "email"
        ]
        app.launchEnvironment["ARGENTUM_UI_TEST_SEED"] = "1"
        app.launchEnvironment["ARGENTUM_MONEY_TRACE"] = "1"
        return app
    }

    @MainActor
    private func enterAddTransactionAmount(_ amount: String, in app: XCUIApplication) {
        openAddTransaction(in: app)
        selectWalletAndCategory(in: app)
        typeAmountCharacterByCharacter(amount, into: amountField(in: app))
    }

    @MainActor
    private func openAddTransaction(in app: XCUIApplication) {
        let addTransactionButton = app.buttons["Add transaction"]
        XCTAssertTrue(addTransactionButton.waitForExistence(timeout: 10))
        addTransactionButton.tap()
    }

    @MainActor
    private func selectWalletAndCategory(in app: XCUIApplication) {
        let walletPicker = app.buttons["Select wallet"]
        XCTAssertTrue(walletPicker.waitForExistence(timeout: 10))
        walletPicker.tap()
        XCTAssertTrue(app.buttons["UI Test Wallet"].waitForExistence(timeout: 5))
        app.buttons["UI Test Wallet"].tap()

        let categoryPicker = app.buttons["Select tag"]
        XCTAssertTrue(categoryPicker.waitForExistence(timeout: 10))
        categoryPicker.tap()
        XCTAssertTrue(app.buttons["Groceries"].waitForExistence(timeout: 5))
        app.buttons["Groceries"].tap()
    }

    private func amountField(in app: XCUIApplication) -> XCUIElement {
        let amountField = app.textFields["add_transaction.amount"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 10))
        amountField.tap()
        return amountField
    }

    private func assertRuntimeDebugPanel(path: String, in app: XCUIApplication) {
        let marker = app.staticTexts["money_runtime_debug.marker"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        XCTAssertEqual(marker.label, "Runtime: MI-RUNTIME-TRACE-1")

        let pathLabel = app.staticTexts["money_runtime_debug.path"]
        XCTAssertTrue(pathLabel.waitForExistence(timeout: 10))
        XCTAssertEqual(pathLabel.label, "Path: \(path)")
    }

    private func assertInFieldRuntimeMarker(_ marker: String, in app: XCUIApplication) {
        let markerLabel = app.staticTexts["raw_amount_field.runtime_marker"]
        XCTAssertTrue(markerLabel.waitForExistence(timeout: 10))
        XCTAssertEqual(markerLabel.label, marker)
    }

    private func tapAccessoryButton(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private func typeAmountCharacterByCharacter(_ amount: String, into field: XCUIElement) {
        var expectedValue = ""
        for character in amount {
            let fragment = String(character)
            field.typeText(fragment)
            expectedValue.append(character)
            XCTAssertEqual(field.value as? String, expectedValue)
        }
    }

    @MainActor
    private func saveAddTransaction(in app: XCUIApplication) {
        let saveButton = app.buttons["add_transaction.save"]
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()
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
