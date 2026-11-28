import XCTest
import UIKit

final class JoystickUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private func launch(openMode: Bool = true, logInput: Bool = true, additionalArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-jellyfin.enabled", "NO", "-page", "0",
                               "-demoInputLog", logInput ? "YES" : "NO", "-demoEyesFree", openMode ? "YES" : "NO"]
        app.launchArguments += additionalArguments
        app.launch()
        if openMode { XCTAssertTrue(stick.waitForExistence(timeout: 10)) }
    }

    private var log: XCUIElement { app.staticTexts["eyesFreeInputLog"] }
    private var stick: XCUIElement { app.descendants(matching: .any).matching(identifier: "eyesFreeStick").firstMatch }
    private var count: Int { Int(log.label.split(separator: ":").first ?? "-1") ?? -1 }

    func testHapticFeedbackSettingReflectsTheConfiguredPreference() {
        for value in ["NO", "YES"] {
            launch(openMode: false, additionalArguments: ["-demoSheet", "settings", "-haptics.enabled", value])
            let haptics = app.switches["Haptic Feedback"]
            XCTAssertTrue(haptics.waitForExistence(timeout: 5))
            XCTAssertEqual(haptics.value as? String, value == "YES" ? "1" : "0")
            app.terminate()
        }
    }

    func testFirstRemoteGuideAfterPairingASavedTVCanBeSkippedAndReopened() {
        let arguments = ["-demoGuideTestProfile", UUID().uuidString]
        launch(openMode: false, additionalArguments: arguments + ["-demoUnpaired", "YES"])
        let offer = app.buttons["firstRemoteGuide"]
        let pair = app.buttons["Pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
        XCTAssertFalse(offer.exists)
        pair.tap()
        let code = app.textFields["Pairing code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.typeText("123456")
        XCTAssertTrue(offer.waitForExistence(timeout: 5))
        app.buttons["skipRemoteGuide"].tap()
        XCTAssertTrue(offer.waitForNonExistence(timeout: 5))
        selectMode("eyesFree", title: "Eyes-free")
        XCTAssertTrue(app.staticTexts["Drag to move · Tap for OK"].exists)

        app.terminate()
        launch(additionalArguments: arguments)
        XCTAssertFalse(app.buttons["firstRemoteGuide"].exists)

        app.buttons["Settings"].tap()
        let help = app.buttons["remoteGuideInSettings"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        help.tap()
        XCTAssertTrue(app.navigationBars["How to use the remote"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Use the joystick"].exists)
    }

    func testPairingExplainsTheCodeBeforeTheUserStarts() {
        launch(openMode: false, additionalArguments: ["-demoUnpaired", "YES"])
        let explanation = app.staticTexts["Choose Pair, then enter the code shown on your TV."]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Pairing code"].exists)
        app.buttons["Pair"].tap()
        XCTAssertTrue(app.textFields["Pairing code"].waitForExistence(timeout: 5))
    }

    func testCursorSettingsAreOnDemandAndTouchpadRemainsAvailable() {
        launch(openMode: false, additionalArguments: ["-demoLGCursor", "YES", "-padMode", "cursor"])
        let settings = app.buttons["lgCursorSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let touchpad = app.descendants(matching: .any).matching(identifier: "lgCursorTouchpad").firstMatch
        XCTAssertTrue(touchpad.isHittable)
        assertCursorHintInside(touchpad)
        XCTAssertFalse(app.buttons["Click"].exists)
        XCTAssertFalse(app.sliders["Cursor speed"].exists)
        XCTAssertFalse(app.switches["Reverse scrolling"].exists)
        captureKeyboard("LG cursor instructions inside the touchpad")

        settings.tap()
        let sheet = app.navigationBars["Cursor Settings"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Cursor speed"].isHittable)
        XCTAssertTrue(app.switches["Reverse scrolling"].isHittable)
        sheet.buttons["Done"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(touchpad.isHittable)
        XCTAssertFalse(app.buttons["Click"].exists)
    }

    func testSwitchPersistentModes() {
        launch(openMode: false)
        selectMode("eyesFree", title: "Eyes-free")
        XCTAssertTrue(stick.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Eyes-free remote"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        selectMode("standard", title: "Directional pad")
        XCTAssertFalse(stick.exists)
    }

    func testTVAppsOpenOnDemandAndReturnToTheSameRemote() {
        launch()
        let apps = app.navigationBars["Apps"]
        XCTAssertFalse(apps.exists)
        XCTAssertFalse(app.staticTexts["TV Apps"].exists)

        app.buttons["TV Apps"].tap()
        XCTAssertTrue(apps.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open YouTube"].exists)

        apps.buttons["Done"].tap()
        XCTAssertTrue(stick.waitForExistence(timeout: 5))
        XCTAssertEqual(log.label, "0:None")

        app.buttons["TV Apps"].tap()
        let youtube = app.buttons["Open YouTube"]
        XCTAssertTrue(youtube.waitForExistence(timeout: 5))
        youtube.tap()
        XCTAssertTrue(stick.waitForExistence(timeout: 5))
        XCTAssertFalse(apps.exists)
    }

    func testBookControlsSwapSidesAndRememberTheMainRemote() throws {
        try requireDuoPosture("book")
        launch()
        let swap = app.buttons["bookSwapSides"]
        XCTAssertTrue(swap.waitForExistence(timeout: 5))

        let remoteStartedOnLeft = stick.frame.midX < swap.frame.midX
        let volume = app.buttons["Volume up"]
        XCTAssertTrue(volume.isHittable)
        XCTAssertEqual(stick.frame.midX < volume.frame.midX, remoteStartedOnLeft)
        let tvPickers = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Living Room TV"))
        let tv = tvPickers.firstMatch
        XCTAssertEqual(tvPickers.count, 1)
        XCTAssertTrue(tv.label.contains("Connected"))
        XCTAssertLessThan(tv.frame.maxY, volume.frame.minY)
        XCTAssertEqual(stick.frame.midX < tv.frame.midX, remoteStartedOnLeft)
        captureKeyboard("Book TV picker on the \(remoteStartedOnLeft ? "right" : "left")")
        swap.tap()
        defer {
            if swap.isHittable && (stick.frame.midX < swap.frame.midX) != remoteStartedOnLeft { swap.tap() }
        }
        XCTAssertEqual(stick.frame.midX < swap.frame.midX, !remoteStartedOnLeft)
        XCTAssertEqual(log.label, "0:None")
        XCTAssertTrue(app.staticTexts["Volume"].isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "Volume up").count, 1)
        XCTAssertEqual(stick.frame.midX < volume.frame.midX, !remoteStartedOnLeft)
        XCTAssertEqual(stick.frame.midX < tv.frame.midX, !remoteStartedOnLeft)
        captureKeyboard("Book TV picker on the \(remoteStartedOnLeft ? "left" : "right")")
        tv.tap()
        let devices = app.navigationBars["TVs"]
        XCTAssertTrue(devices.waitForExistence(timeout: 5))
        devices.buttons["Done"].tap()
        volume.tap()
        XCTAssertEqual(log.label, "1:Volume up")

        app.terminate()
        launch()
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        XCTAssertEqual(stick.frame.midX < swap.frame.midX, !remoteStartedOnLeft)
        XCTAssertEqual(stick.frame.midX < app.buttons["Volume up"].frame.midX, !remoteStartedOnLeft)
        XCTAssertEqual(stick.frame.midX < tv.frame.midX, !remoteStartedOnLeft)
        XCTAssertEqual(log.label, "0:None")
    }

    func testBookWatchAndAppsStayOppositeActiveRemote() throws {
        try requireDuoPosture("book")
        launch()
        let swap = app.buttons["bookSwapSides"]
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        let initialRemoteIsOnLeft = stick.frame.midX < swap.frame.midX
        let remote = app.buttons["Remote"]
        let watch = app.buttons["Watch"]
        let watchTitle = app.staticTexts["Watch"].firstMatch
        let allApps = app.buttons["All apps"]
        let appsTitle = app.staticTexts["Apps"]
        let youtube = app.buttons["Open YouTube"]

        defer {
            if swap.isHittable && (stick.frame.midX < swap.frame.midX) != initialRemoteIsOnLeft { swap.tap() }
        }
        for remoteIsOnLeft in [initialRemoteIsOnLeft, !initialRemoteIsOnLeft] {
            let remoteFrame = stick.frame
            func assertInCompanion(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertTrue(element.isHittable, file: file, line: line)
                if remoteIsOnLeft {
                    XCTAssertGreaterThan(element.frame.minX, remoteFrame.maxX, file: file, line: line)
                } else {
                    XCTAssertLessThan(element.frame.maxX, remoteFrame.minX, file: file, line: line)
                }
            }

            assertInCompanion(remote)
            assertInCompanion(watch)
            let switcherFrame = remote.frame.union(watch.frame)
            XCTAssertFalse(allApps.exists)
            watch.tap()
            XCTAssertTrue(allApps.waitForExistence(timeout: 5))
            assertInCompanion(watchTitle)
            assertInCompanion(allApps)
            assertInCompanion(remote)
            assertInCompanion(watch)
            XCTAssertEqual(remote.frame.union(watch.frame), switcherFrame)
            XCTAssertEqual(stick.frame, remoteFrame)
            XCTAssertFalse(swap.exists)
            let beforeTap = count
            stick.tap()
            XCTAssertEqual(log.label, "\(beforeTap + 1):OK")
            captureKeyboard("Book Watch on the \(remoteIsOnLeft ? "right" : "left")")

            allApps.tap()
            XCTAssertTrue(appsTitle.waitForExistence(timeout: 5))
            assertInCompanion(youtube)
            XCTAssertEqual(stick.frame, remoteFrame)
            stick.tap()
            XCTAssertEqual(log.label, "\(beforeTap + 2):OK")
            captureKeyboard("Book TV Apps on the \(remoteIsOnLeft ? "right" : "left")")
            app.buttons["Done"].tap()
            XCTAssertTrue(allApps.waitForExistence(timeout: 5))
            remote.tap()
            XCTAssertTrue(swap.waitForExistence(timeout: 5))

            app.buttons["TV Apps"].tap()
            XCTAssertTrue(appsTitle.waitForExistence(timeout: 5))
            assertInCompanion(youtube)
            XCTAssertEqual(stick.frame, remoteFrame)
            XCTAssertFalse(app.navigationBars["Apps"].exists)
            youtube.tap()
            XCTAssertTrue(swap.waitForExistence(timeout: 5))
            swap.tap()
        }
        XCTAssertEqual(stick.frame.midX < swap.frame.midX, initialRemoteIsOnLeft)
    }

    func testIPadLandscapeControlsSwapAndKeepTVAppsOnDemand() throws {
        try requireIPad()
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .landscapeRight
        launch()

        let swap = app.buttons["ipadSwapSides"]
        let volume = app.buttons["Volume up"]
        let media = app.buttons["Media Controls"]
        let pinnedMedia = app.staticTexts["ipadPinnedMedia"]
        let unpin = app.buttons["Unpin Media Controls"]
        if unpin.exists { unpin.tap() }
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        XCTAssertFalse(pinnedMedia.exists)
        XCTAssertFalse(volume.exists)
        XCTAssertTrue(swap.isHittable)
        let home = app.buttons["Home"]
        let homeStartedOnLeft = home.frame.midX < stick.frame.midX
        swap.tap()
        XCTAssertEqual(home.frame.midX < stick.frame.midX, !homeStartedOnLeft)
        XCTAssertFalse(pinnedMedia.exists)
        swap.tap()
        XCTAssertEqual(home.frame.midX < stick.frame.midX, homeStartedOnLeft)

        media.tap()
        let pin = app.buttons["Pin on iPad"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertTrue(volume.isHittable)
        pin.tap()
        defer { if unpin.isHittable { unpin.tap() } }
        XCTAssertTrue(pinnedMedia.waitForExistence(timeout: 5))
        XCTAssertTrue(pin.waitForNonExistence(timeout: 5))
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        XCTAssertTrue(volume.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "Volume up").count, 1)
        let startedOnLeft = stick.frame.midX < volume.frame.midX
        XCTAssertGreaterThan(stick.frame.width, app.frame.width * 0.55)
        XCTAssertGreaterThanOrEqual(stick.frame.minY - app.buttons["Home"].frame.maxY, 15)
        let playback = app.staticTexts["Playback"]
        XCTAssertTrue(playback.isHittable)
        XCTAssertGreaterThanOrEqual(playback.frame.minY - volume.frame.maxY, 16)
        XCTAssertGreaterThanOrEqual(app.buttons["Input"].frame.minY - app.buttons["Fast forward"].frame.maxY, 16)

        swap.tap()
        defer {
            if swap.isHittable && stick.exists {
                let sideChanged = volume.exists
                    ? (stick.frame.midX < volume.frame.midX) != startedOnLeft
                    : (home.frame.midX < stick.frame.midX) != homeStartedOnLeft
                if sideChanged { swap.tap() }
            }
        }
        XCTAssertEqual(stick.frame.midX < volume.frame.midX, !startedOnLeft)
        XCTAssertEqual(log.label, "0:None")
        volume.tap()
        XCTAssertEqual(log.label, "1:Volume up")

        let apps = app.navigationBars["Apps"]
        XCTAssertFalse(apps.exists)
        app.buttons["TV Apps"].tap()
        XCTAssertTrue(apps.waitForExistence(timeout: 5))
        apps.buttons["Done"].tap()
        XCTAssertTrue(stick.isHittable)

        app.terminate()
        launch(logInput: false)
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        XCTAssertEqual(stick.frame.midX < volume.frame.midX, !startedOnLeft)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad landscape joystick"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        selectMode("standard", title: "Directional pad")
        let ok = app.buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5))
        XCTAssertTrue(ok.isHittable)
        XCTAssertEqual(ok.frame.midX < volume.frame.midX, !startedOnLeft)
        let directional = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        directional.name = "iPad landscape directional pad"
        directional.lifetime = .keepAlways
        add(directional)

        let landscapeVolumeX = volume.frame.midX
        selectMode("keyboard", title: "Keyboard")
        XCTAssertTrue(app.buttons["a"].waitForExistence(timeout: 5))
        XCTAssertTrue(pinnedMedia.isHittable)
        XCTAssertTrue(volume.isHittable)
        XCTAssertEqual(volume.frame.midX, landscapeVolumeX, accuracy: 1)
        let firstKey = app.buttons["q"]
        let keysAreOnLeft = firstKey.frame.midX < ok.frame.midX
        XCTAssertEqual(firstKey.frame.midX < volume.frame.midX, keysAreOnLeft)
        assertClearBelowDPad()
        XCTAssertLessThan(app.buttons["Clear"].frame.maxY, pinnedMedia.frame.minY)
        let landscapeKeyboard = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscapeKeyboard.name = "iPad landscape keyboard with pinned media"
        landscapeKeyboard.lifetime = .keepAlways
        add(landscapeKeyboard)

        swap.tap()
        XCTAssertEqual(firstKey.frame.midX < ok.frame.midX, !keysAreOnLeft)
        XCTAssertEqual(firstKey.frame.midX < volume.frame.midX, !keysAreOnLeft)
        device.orientation = .portrait
        XCTAssertTrue(swap.waitForNonExistence(timeout: 5))
        XCTAssertTrue(ok.isHittable)
        XCTAssertTrue(pinnedMedia.isHittable)
        XCTAssertTrue(volume.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "Volume up").count, 1)
        XCTAssertLessThan(volume.frame.maxY, firstKey.frame.minY)
        XCTAssertLessThan(ok.frame.maxY, firstKey.frame.minY)
        XCTAssertGreaterThanOrEqual(pinnedMedia.frame.minY - app.buttons["Home"].frame.maxY, 48)
        let mediaToPad = ok.frame.midY - volume.frame.maxY
        XCTAssertGreaterThanOrEqual(mediaToPad, 110)
        if app.frame.height >= 1300 {
            XCTAssertGreaterThanOrEqual(mediaToPad, 158)
        } else if app.frame.height >= 1100 {
            XCTAssertGreaterThanOrEqual(mediaToPad, 130)
        }
        XCTAssertGreaterThanOrEqual(app.buttons["1"].frame.minY - ok.frame.midY, 90)
        XCTAssertLessThan(app.buttons["Watch"].frame.minY - app.buttons["Space"].frame.maxY, 44)
        let portraitKeyboard = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portraitKeyboard.name = "iPad portrait keyboard with pinned media"
        portraitKeyboard.lifetime = .keepAlways
        add(portraitKeyboard)

        unpin.tap()
        XCTAssertTrue(pinnedMedia.waitForNonExistence(timeout: 5))
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        XCTAssertFalse(volume.exists)

        let portraitFrame = app.frame
        device.orientation = .landscapeRight
        waitForLandscapeIfExpected(portraitFrame)
        selectMode("eyesFree", title: "Eyes-free")
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        media.tap()
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertTrue(pin.isHittable)
        let pickerScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        pickerScreenshot.name = "iPad media controls popover"
        pickerScreenshot.lifetime = .keepAlways
        add(pickerScreenshot)
        app.buttons["Close Media Controls"].tap()
    }

    func testIPadKeyboardKeepsNavigationAndKeysTogether() throws {
        try requireIPad()
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .portrait
        launch(openMode: false, logInput: false, additionalArguments: ["-padMode", "keyboard", "-ipad.mediaControlsPinned", "NO"])

        let home = app.buttons["Home"]
        let ok = app.buttons["OK"]
        let letter = app.buttons["a"]
        let space = app.buttons["Space"]
        let firstKey = app.buttons["q"]
        let lastKey = app.buttons["p"]
        let clear = app.buttons["Clear"]
        let portraitFrame = app.frame
        for orientation: UIDeviceOrientation in [.portrait, .landscapeRight] {
            device.orientation = orientation
            if orientation.isLandscape { waitForLandscapeIfExpected(portraitFrame) }
            XCTAssertTrue(letter.waitForExistence(timeout: 5))
            XCTAssertTrue(home.isHittable)
            XCTAssertTrue(ok.isHittable)
            XCTAssertTrue(letter.isHittable)
            XCTAssertTrue(space.isHittable)
            assertKeyboardEditingKeys()
            XCTAssertTrue(app.buttons["1"].isHittable)
            XCTAssertEqual(clear.frame.width, 64, accuracy: 1)
            XCTAssertEqual(clear.frame.height, 48, accuracy: 1)
            assertClearBelowDPad()
            let keys = firstKey.frame.union(lastKey.frame)
            XCTAssertGreaterThanOrEqual(firstKey.frame.width, 44)
            XCTAssertGreaterThanOrEqual(firstKey.frame.height, 43.5)
            XCTAssertGreaterThanOrEqual(ok.frame.width, 68)
            XCTAssertGreaterThanOrEqual(app.buttons["w"].frame.minX - firstKey.frame.maxX, 8)
            XCTAssertGreaterThan(space.frame.midY, app.frame.midY)
            if orientation.isLandscape {
                XCTAssertTrue(ok.frame.maxX < keys.minX || ok.frame.minX > keys.maxX)
                XCTAssertGreaterThan(keys.width, app.frame.width * 0.55)
                XCTAssertEqual(clear.frame.midX > keys.midX, ok.frame.midX > keys.midX)
            } else {
                XCTAssertLessThan(ok.frame.maxY, keys.minY)
                XCTAssertGreaterThan(keys.width, app.frame.width * 0.73)
                XCTAssertLessThan(clear.frame.maxY, app.buttons["1"].frame.minY)
                XCTAssertGreaterThanOrEqual(app.buttons["1"].frame.minY - ok.frame.midY, 90)
                XCTAssertLessThan(app.buttons["Watch"].frame.minY - space.frame.maxY, 44)
            }
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = orientation == .portrait ? "iPad portrait keyboard" : "iPad landscape keyboard"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    func testIPhoneKeyboardFitsPortraitAndLandscape() throws {
        try requireStandardIPhone()
        assertPhoneKeyboardFitsPortraitAndLandscape(deviceName: "iPhone")
    }

    @MainActor
    func testHoldingAPortraitKeyboardCharacterTypesOnceAndResetsShift() throws {
        try requireStandardIPhone()
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .portrait
        launch(openMode: false, additionalArguments: ["-padMode", "keyboard"])

        app.buttons["Shift"].tap()
        let capitalQ = app.buttons["Q"]
        XCTAssertTrue(capitalQ.waitForExistence(timeout: 5))
        try assertHeldCapitalQ(capitalQ)
        XCTAssertEqual(app.staticTexts["demoPadInputLog"].label, "1:Q")
        XCTAssertTrue(app.buttons["q"].isHittable)
        app.buttons["q"].tap()
        XCTAssertEqual(app.staticTexts["demoPadInputLog"].label, "2:q")
    }

    func testNarrowIPhonePortraitKeyboardKeepsClearBelowTheDPad() throws {
        try requireStandardIPhone()
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .portrait
        launch(openMode: false, logInput: false, additionalArguments: ["-padMode", "keyboard", "-demoKeyboardWidth", "310"])

        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 5))
        assertKeyboardEditingKeys()
        assertKeyboardAbovePageSwitcher()
        assertClearBelowDPad()
        let keys = app.buttons["q"].frame.union(app.buttons["p"].frame)
        XCTAssertEqual(app.buttons["OK"].frame.midX, keys.midX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(keys.minY - app.buttons["Clear"].frame.maxY, 21)
    }

    private func requireStandardIPhone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Requires an iPhone simulator.")
        let environment = ProcessInfo.processInfo.environment
        // The model identifier also covers Duo runs without a posture fixture.
        try XCTSkipIf(environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" ||
                      environment["OPEN_REMOTE_DUO_POSTURE"] != nil,
                      "Duo uses its posture-specific keyboard tests.")
    }

    func testShortPhoneLandscapeKeepsTypingReachableWithPairingBanner() throws {
        try requireStandardIPhone()
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .landscapeRight
        launch(openMode: false, logInput: false, additionalArguments: ["-padMode", "keyboard", "-demoUnpaired", "YES"])
        XCTAssertTrue(app.buttons["Pair"].waitForExistence(timeout: 5))
        let typing = app.buttons["phoneKeyboardSheet"]
        XCTAssertTrue(typing.isHittable)
        XCTAssertTrue(app.buttons["OK"].isHittable)
        XCTAssertTrue(app.buttons["Clear"].isHittable)
        XCTAssertFalse(app.buttons["Return"].exists)
        XCTAssertLessThanOrEqual(typing.frame.maxY, app.buttons["Watch"].frame.minY)
        XCTAssertTrue(app.buttons["Home"].isHittable)

        typing.tap()
        let field = app.textFields["Search or type…"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        app.buttons["Done"].tap()
        XCTAssertTrue(typing.isHittable)
    }

    func testFoldedDuoKeyboardFitsPortraitAndLandscape() throws {
        try requireDuoPosture("closed")
        assertPhoneKeyboardFitsPortraitAndLandscape(deviceName: "iPhone Duo folded", folded: true)
    }

    private func assertPhoneKeyboardFitsPortraitAndLandscape(deviceName: String, folded: Bool = false) {
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .portrait
        launch(openMode: false, logInput: false, additionalArguments: ["-padMode", "keyboard"])

        let space = app.buttons["Space"]
        XCTAssertTrue(space.waitForExistence(timeout: 5))
        let portraitFrame = app.frame
        for orientation: UIDeviceOrientation in [.portrait, .landscapeRight] {
            device.orientation = orientation
            if orientation.isLandscape { waitForLandscapeIfExpected(portraitFrame) }
            assertKeyboardEditingKeys()
            XCTAssertFalse(app.buttons["1"].exists)
            assertKeyboardAbovePageSwitcher()
            let ok = app.buttons["OK"]
            XCTAssertTrue(ok.isHittable)
            if orientation.isPortrait {
                let keyRow = app.buttons["q"].frame.union(app.buttons["p"].frame)
                XCTAssertEqual(ok.frame.midX, keyRow.midX, accuracy: 1)
                let clear = app.buttons["Clear"]
                XCTAssertGreaterThan(clear.frame.minX, ok.frame.maxX)
                XCTAssertEqual(clear.frame.midY, ok.frame.midY, accuracy: 1)
                if !folded {
                    if portraitFrame.width >= 380 {
                        XCTAssertGreaterThanOrEqual(ok.frame.width, 78)
                    }
                    let padRadius = ok.frame.width / 0.40 / 2
                    XCTAssertGreaterThanOrEqual(clear.frame.minX - ok.frame.midX, padRadius + 11)
                    XCTAssertEqual(keyRow.height, 52, accuracy: 1)
                    XCTAssertEqual(space.frame.height, 52, accuracy: 1)
                    XCTAssertLessThanOrEqual(app.buttons["Remote"].frame.minY - space.frame.maxY, 40)
                    XCTAssertGreaterThan(keyRow.minY - app.buttons["Down"].frame.maxY, 30)
                }
            } else {
                assertClearBelowDPad()
                XCTAssertLessThan(ok.frame.maxX, app.buttons["q"].frame.minX)
            }
            let layout = orientation.isLandscape ? "landscape" : "portrait"
            captureKeyboard("\(deviceName) \(layout) keyboard")
        }
        app.buttons["Numbers and symbols"].tap()
        XCTAssertTrue(app.buttons["Letters"].isHittable)
        XCTAssertTrue(app.buttons["1"].isHittable)
        XCTAssertTrue(space.isHittable)
        if deviceName == "iPhone" { captureKeyboard("iPhone numbers keyboard") }
        app.buttons["More symbols"].tap()
        XCTAssertTrue(app.buttons["¥"].isHittable)
        XCTAssertTrue(app.buttons["Return"].isHittable)
        app.buttons["Numbers and punctuation"].tap()
        XCTAssertTrue(app.buttons["1"].isHittable)
        app.buttons["Letters"].tap()
        app.buttons["Watch"].tap()
        XCTAssertTrue(app.buttons["Remote"].isHittable)
        app.buttons["Remote"].tap()
        XCTAssertTrue(space.waitForExistence(timeout: 5))
        assertKeyboardAbovePageSwitcher()
    }

    private func assertClearBelowDPad() {
        let clear = app.buttons["Clear"]
        let down = app.buttons["Down"]
        XCTAssertTrue(clear.isHittable)
        XCTAssertEqual(clear.frame.midX, app.buttons["OK"].frame.midX, accuracy: 1)
        XCTAssertLessThan(down.frame.maxY, clear.frame.minY)
    }

    private func assertKeyboardEditingKeys(compact: Bool = false) {
        let clear = app.buttons["Clear"]
        let delete = app.buttons["Delete"]
        let enter = app.buttons["Return"]
        let space = app.buttons["Space"]
        XCTAssertEqual(app.buttons.matching(identifier: "Delete").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "Return").count, 1)
        for button in [clear, delete, enter] {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width, 43.5)
        }
        XCTAssertEqual(enter.frame.midY, space.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(enter.frame.minX, space.frame.maxX)
        XCTAssertGreaterThan(delete.frame.minX, app.buttons["Shift"].frame.maxX)
        if !compact {
            let lastLetter = app.buttons["m"]
            XCTAssertEqual(delete.frame.midY, lastLetter.frame.midY, accuracy: 1)
            XCTAssertGreaterThan(delete.frame.minX, lastLetter.frame.maxX)
        }
    }

    private func assertKeyboardAbovePageSwitcher() {
        let watch = app.buttons["Watch"]
        let remote = app.buttons["Remote"]
        XCTAssertTrue(watch.isHittable)
        XCTAssertTrue(remote.isHittable)
        for label in ["q", "z", "Delete", "Numbers and symbols", "Space", "Return"] {
            let key = app.buttons[label]
            XCTAssertTrue(key.isHittable, "\(label) should be reachable without scrolling")
            XCTAssertLessThan(key.frame.maxY, min(remote.frame.minY, watch.frame.minY))
        }
    }

    private func captureKeyboard(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func assertHeldCapitalQ(_ key: XCUIElement) throws {
        XCTAssertTrue(key.isHittable)
        let keyFrame = key.frame
        let window = app.windows.firstMatch
        let windowFrame = window.frame
        var heldScreenshot: XCUIScreenshot?
        // XCTest services the main run loop while its synthesized touch is held down.
        let capture = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated { heldScreenshot = window.screenshot() }
        }
        RunLoop.main.add(capture, forMode: .common)
        key.press(forDuration: 4)
        capture.invalidate()

        let screenshot = try XCTUnwrap(heldScreenshot, "Expected a screenshot during the press")
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Keyboard while holding Shifted Q"
        attachment.lifetime = .keepAlways
        add(attachment)

        let image = try XCTUnwrap(UIImage(data: screenshot.pngRepresentation))
        let scale = image.size.width / windowFrame.width
        let inPixels = CGAffineTransform(translationX: -windowFrame.minX, y: -windowFrame.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func crop(_ bounds: CGRect) -> UIImage {
            let frame = bounds.integral
            return UIGraphicsImageRenderer(size: frame.size, format: format).image { _ in
                image.draw(at: CGPoint(x: -frame.minX, y: -frame.minY))
            }
        }

        let previewRegion = CGRect(x: keyFrame.minX - 10, y: keyFrame.minY - 56,
                                   width: max(keyFrame.width + 20, 64), height: 56)
        let cropRect = previewRegion.applying(inPixels).integral
        let previewCrop = crop(cropRect)
        let clearance = XCTAttachment(image: previewCrop)
        clearance.name = "Keyboard preview clearance"
        add(clearance)
        let previewBounds = try XCTUnwrap(coloredBounds(in: previewCrop) { red, green, blue in
            green > 100 && Int(green) - Int(red) > 30 && Int(green) - Int(blue) > 12
        }, "Expected the preview outline above the pressed key")
        let previewBottom = previewRegion.minY + previewBounds.maxY * previewRegion.height
        let previewCenter = previewRegion.minX + previewBounds.midX * previewRegion.width
        XCTAssertEqual(keyFrame.minY - previewBottom, 8, accuracy: 2)
        XCTAssertEqual(previewCenter, keyFrame.midX, accuracy: 5)

        let previewText = CGRect(x: cropRect.minX + previewBounds.minX * cropRect.width,
                                 y: cropRect.minY + previewBounds.minY * cropRect.height,
                                 width: previewBounds.width * cropRect.width,
                                 height: previewBounds.height * cropRect.height)
        let bubble = crop(previewText)
        let face = crop(keyFrame.applying(inPixels))
        for (name, image) in [("preview", bubble), ("held key", face)] {
            let glyph = try XCTUnwrap(coloredBounds(in: image) { red, green, blue in
                min(red, green, blue) > 180
            }, "Expected a glyph on the \(name)")
            let aspect = glyph.width * image.size.width / (glyph.height * image.size.height)
            // In the rounded key font, an uppercase Q is wider relative to its height than lowercase q.
            XCTAssertTrue((0.75...0.90).contains(aspect), "Expected uppercase Q on the \(name), aspect \(aspect)")
        }
    }

    func testIPadNarrowKeyboardKeepsUsableKeys() throws {
        try requireIPad()
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .portrait
        launch(openMode: false, logInput: false,
               additionalArguments: ["-padMode", "keyboard", "-demoKeyboardWidth", "390", "-ipad.mediaControlsPinned", "NO"])

        let letter = app.buttons["a"]
        XCTAssertTrue(letter.waitForExistence(timeout: 5))
        XCTAssertTrue(letter.isHittable)
        XCTAssertGreaterThanOrEqual(letter.frame.width, 28)
        XCTAssertTrue(app.buttons["Home"].isHittable)
        assertClearBelowDPad()
        assertKeyboardEditingKeys()
        let q = app.buttons["q"]
        let p = app.buttons["p"]
        let l = app.buttons["l"]
        XCTAssertTrue(p.isHittable)
        XCTAssertEqual(q.frame.midY, p.frame.midY, accuracy: 1)
        XCTAssertEqual(letter.frame.midY, l.frame.midY, accuracy: 1)
        XCTAssertLessThan(q.frame.maxY, letter.frame.minY)
        XCTAssertGreaterThanOrEqual(q.frame.minY - app.buttons["Clear"].frame.maxY, 12)
        for label in ["Shift", "Delete", "Return"] {
            let key = app.buttons[label]
            XCTAssertTrue(key.isHittable)
            XCTAssertGreaterThanOrEqual(key.frame.width, 43.5)
            XCTAssertGreaterThanOrEqual(key.frame.height, 43.5)
        }
        XCTAssertFalse(app.buttons["1"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad narrow keyboard fixture"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Numbers and symbols"].tap()
        XCTAssertTrue(app.buttons["1"].isHittable)
        XCTAssertTrue(app.buttons["Return"].isHittable)
    }

    func testIPadLandscapeCursorKeepsSettingsAndVolumeReachable() throws {
        try requireIPad()
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .landscapeRight
        launch(openMode: false, logInput: false,
               additionalArguments: ["-demoLGCursor", "YES", "-padMode", "cursor", "-ipad.mediaControlsPinned", "YES"])

        let settings = app.buttons["lgCursorSettings"]
        let touchpad = app.descendants(matching: .any).matching(identifier: "lgCursorTouchpad").firstMatch
        let volume = app.buttons["Volume up"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(touchpad.isHittable)
        XCTAssertTrue(volume.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "Volume up").count, 1)
        XCTAssertGreaterThan(touchpad.frame.height, 240)
        XCTAssertGreaterThan(touchpad.frame.width, app.frame.width * 0.55)
        XCTAssertGreaterThanOrEqual(touchpad.frame.minY - app.buttons["Home"].frame.maxY, 15)
        let strip = app.descendants(matching: .any).matching(identifier: "Scroll strip").firstMatch
        XCTAssertTrue(strip.isHittable)
        XCTAssertEqual(strip.frame.midX < touchpad.frame.midX, touchpad.frame.midX < volume.frame.midX)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad landscape LG cursor"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        settings.tap()
        let sheet = app.navigationBars["Cursor Settings"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Cursor speed"].isHittable)
        sheet.buttons["Done"].tap()
        XCTAssertTrue(touchpad.isHittable)
    }

    func testIPadLandscapeCursorCanSwapSidesWithMediaUnpinned() throws {
        try assertIPadLandscapeCursorCanSwapSides()
    }

    func testIPadLandscapeCursorCanSwapSidesWithAccessibilityText() throws {
        try assertIPadLandscapeCursorCanSwapSides(accessibilityText: true)
    }

    private func assertIPadLandscapeCursorCanSwapSides(accessibilityText: Bool = false) throws {
        try requireIPad()
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .landscapeRight
        var arguments = ["-demoLGCursor", "YES", "-padMode", "cursor", "-ipad.mediaControlsPinned", "NO"]
        if accessibilityText {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        }
        launch(openMode: false, logInput: false, additionalArguments: arguments)

        let settings = app.buttons["lgCursorSettings"]
        let touchpad = app.descendants(matching: .any).matching(identifier: "lgCursorTouchpad").firstMatch
        let strip = app.descendants(matching: .any).matching(identifier: "Scroll strip").firstMatch
        let swap = app.buttons["ipadCursorSwapSides"]
        let sheet = app.navigationBars["Cursor Settings"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        if accessibilityText { XCTAssertTrue(app.buttons["remoteModePicker"].exists) }
        XCTAssertTrue(app.buttons["Media Controls"].isHittable)
        XCTAssertFalse(app.staticTexts["ipadPinnedMedia"].exists)
        let stripStartedOnLeft = strip.frame.midX < touchpad.frame.midX
        defer {
            if strip.isHittable && (strip.frame.midX < touchpad.frame.midX) != stripStartedOnLeft {
                settings.tap()
                if swap.waitForExistence(timeout: 5) { swap.tap() }
            }
        }

        settings.tap()
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        swap.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(strip.isHittable)
        XCTAssertEqual(strip.frame.midX < touchpad.frame.midX, !stripStartedOnLeft)

        app.terminate()
        launch(openMode: false, logInput: false, additionalArguments: arguments)
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        XCTAssertEqual(strip.frame.midX < touchpad.frame.midX, !stripStartedOnLeft)
        XCTAssertFalse(app.staticTexts["ipadPinnedMedia"].exists)
    }

    private func requireIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an iPad simulator.")
    }

    func testBookPlaybackRepeatsWaitForThePreviousRequestAndStopOnRelease() throws {
        try requireDuoPosture("book")
        launch(additionalArguments: ["-demoInteractiveDelayMS", "900"])
        let forward = app.buttons["Fast forward"]
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        forward.press(forDuration: 1.0)
        XCTAssertEqual(log.label, "2:Fast forward")

        let unexpectedRepeat = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.count > 2
        }, object: nil)
        unexpectedRepeat.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedRepeat], timeout: 0.5), .completed)
    }

    func testBookDirectionalHoldUsesCancellableRepeats() throws {
        try requireDuoPosture("book")
        launch(openMode: false, additionalArguments: ["-padMode", "standard", "-demoInteractiveDelayMS", "900"])
        let ok = app.buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5))
        let target = ok.coordinate(withNormalizedOffset: CGVector(dx: 1.4, dy: 0.5))
        assertDelayedHoldSendsOneRepeat(log: app.staticTexts["demoPadInputLog"], key: "Right") {
            target.press(forDuration: 1)
        }
    }

    func testHandheldDirectionalHoldWaitsForThePreviousRepeat() {
        launch(openMode: false, additionalArguments: ["-padMode", "standard", "-demoInteractiveDelayMS", "900"])
        let ok = app.buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5))
        let target = ok.coordinate(withNormalizedOffset: CGVector(dx: 1.4, dy: 0.5))
        assertDelayedHoldSendsOneRepeat(log: app.staticTexts["demoPadInputLog"], key: "Right") {
            target.press(forDuration: 1)
        }
    }

    func testKeyboardSheetDeleteCanRepeatWhileTheSheetIsOpen() {
        launch(openMode: false, additionalArguments: ["-demoSheet", "keyboard", "-demoInteractiveDelayMS", "900"])
        let delete = app.buttons["Delete on TV"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.press(forDuration: 1)
        app.buttons["Done"].tap()

        let padLog = app.staticTexts["demoPadInputLog"]
        XCTAssertTrue(padLog.waitForExistence(timeout: 5))
        XCTAssertEqual(padLog.label, "2:Delete")
    }

    func testPausedBufferedKeyboardCanHoldDeleteUntilTheLocalTextIsGone() {
        launch(openMode: false, additionalArguments: [
            "-padMode", "keyboard", "-demoConnectionPaused", "YES", "-demoBufferedKeyboard", "YES",
        ])
        let delete = app.buttons.matching(identifier: "Delete").firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled)
        for key in ["q", "w", "e"] { app.buttons[key].tap() }
        XCTAssertTrue(delete.isEnabled)

        delete.press(forDuration: 1)
        XCTAssertFalse(delete.isEnabled)
        XCTAssertEqual(app.staticTexts["demoPadInputLog"].label, "3:e")
    }

    func testTVDeleteIsDisabledOnThePadsAndKeyboardSheetWhilePaused() {
        let paused = ["-demoConnectionPaused", "YES"]
        launch(openMode: false, additionalArguments: paused + ["-padMode", "keyboard"])
        let delete = app.buttons.matching(identifier: "Delete").firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled)

        selectMode("keypad", title: "Number pad")
        XCTAssertTrue(app.buttons["0"].waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled)

        app.terminate()
        launch(openMode: false, additionalArguments: paused + ["-demoSheet", "keyboard"])
        let sheetDelete = app.buttons["Delete on TV"]
        XCTAssertTrue(sheetDelete.waitForExistence(timeout: 5))
        XCTAssertFalse(sheetDelete.isEnabled)
    }

    func testBookPlaybackStopsWhenTheTouchLeavesTheButton() throws {
        try requireDuoPosture("book")
        launch()
        let forward = app.buttons["Fast forward"]
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        let center = forward.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let outside = forward.coordinate(withNormalizedOffset: CGVector(dx: -0.35, dy: 0.5))
        center.press(forDuration: 0.15, thenDragTo: outside, withVelocity: .fast, thenHoldForDuration: 0.7)
        XCTAssertEqual(log.label, "1:Fast forward")
    }

    func testNarrowBookKeyboardActionsRemainReachableAfterSwappingSides() throws {
        try requireDuoPosture("book")
        launch(openMode: false, additionalArguments: ["-padMode", "keyboard", "-demoKeyboardWidth", "164"])
        let swap = app.buttons["bookSwapSides"]
        let clear = app.buttons["Clear"]
        let enter = app.buttons["Return"]
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        XCTAssertTrue(enter.waitForExistence(timeout: 5))
        let originalSide = enter.frame.midX < swap.frame.midX
        swap.tap()
        defer {
            if swap.isHittable && (enter.frame.midX < swap.frame.midX) != originalSide { swap.tap() }
        }
        XCTAssertEqual(enter.frame.midX < swap.frame.midX, !originalSide)
        let delete = app.buttons["Delete"]
        assertKeyboardEditingKeys(compact: true)
        let keys = ["q", "w"]
        for key in keys {
            let button = app.buttons[key]
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            button.tap()
        }
        XCTAssertEqual(app.staticTexts["demoPadInputLog"].label, "2:w")
        clear.tap()
        delete.tap()
        enter.tap()
    }

    func testBookKeyboardKeepsEditingWithTheKeyboard() throws {
        try requireDuoPosture("book")
        launch(openMode: false, logInput: false, additionalArguments: ["-padMode", "keyboard"])
        let swap = app.buttons["bookSwapSides"]
        let clear = app.buttons["Clear"]
        let space = app.buttons["Space"]
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        XCTAssertTrue(space.waitForExistence(timeout: 5))
        assertKeyboardEditingKeys()
        let watch = app.buttons["Watch"]
        XCTAssertEqual(watch.frame.midX > space.frame.midX, swap.frame.midX > space.frame.midX)
        watch.tap()
        XCTAssertTrue(app.buttons["All apps"].waitForExistence(timeout: 5))
        assertKeyboardEditingKeys()
        app.buttons["q"].tap()
        app.buttons["Remote"].tap()
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        captureKeyboard("iPhone Duo Book keyboard")

        let keyboardWasOnLeft = space.frame.midX < swap.frame.midX
        swap.tap()
        defer {
            if space.isHittable && (space.frame.midX < swap.frame.midX) != keyboardWasOnLeft { swap.tap() }
        }
        XCTAssertEqual(space.frame.midX < swap.frame.midX, !keyboardWasOnLeft)
        XCTAssertEqual(clear.frame.midX < swap.frame.midX, !keyboardWasOnLeft)
        assertKeyboardEditingKeys()
    }

    func testBookKeyboardDeleteUsesCancellableRepeats() throws {
        try requireDuoPosture("book")
        launch(openMode: false, additionalArguments: [
            "-padMode", "keyboard", "-demoKeyboardWidth", "164", "-demoInteractiveDelayMS", "900",
        ])
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        for key in ["q", "w", "e"] { app.buttons[key].tap() }
        let padLog = app.staticTexts["demoPadInputLog"]
        XCTAssertEqual(padLog.label, "3:e")
        assertDelayedHoldSendsOneRepeat(log: padLog, key: "Delete", expectedCount: 5) {
            delete.press(forDuration: 1)
        }
        app.buttons["Clear"].tap()
        XCTAssertEqual(padLog.label, "6:Delete")
    }

    func testTabletopKeypadMediaHoldUsesCancellableRepeats() throws {
        try requireDuoPosture("tabletop")
        launch(openMode: false, additionalArguments: ["-padMode", "keypad", "-demoInteractiveDelayMS", "900"])
        let forward = app.buttons["Fast forward"]
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        XCTAssertTrue(forward.isHittable)
        assertDelayedHoldSendsOneRepeat(log: app.staticTexts["demoPadInputLog"], key: "Fast forward") {
            forward.press(forDuration: 1)
        }
    }

    private func assertDelayedHoldSendsOneRepeat(log: XCUIElement, key: String, expectedCount: Int = 2, hold: () -> Void) {
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        hold()
        let expected = "\(expectedCount):\(key)"
        XCTAssertEqual(log.label, expected)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            log.label != expected
        }, object: nil)
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0.5), .completed)
    }

    func testTabletopShowsTVStatusAboveTheRemoteAndPlayback() throws {
        try requireDuoPosture("tabletop")
        launch(additionalArguments: ["-demoForegroundAppPackage", "com.google.android.youtube.tv"])
        let tv = app.buttons["tabletopTVSelection"]
        XCTAssertTrue(tv.waitForExistence(timeout: 5))

        XCTAssertTrue(tv.label.contains("Living Room TV"))
        XCTAssertTrue(tv.label.contains("Connected"))
        let reportedApp = app.descendants(matching: .any)["tabletopForegroundApp"].firstMatch
        XCTAssertTrue(reportedApp.isHittable)
        XCTAssertEqual(reportedApp.label, "Last reported app, YouTube")
        let play = app.buttons["Play or pause"]
        let volume = app.buttons["Volume down"]
        XCTAssertTrue(play.isHittable)
        XCTAssertTrue(volume.isHittable)
        XCTAssertGreaterThan(stick.frame.midY, tv.frame.midY)
        XCTAssertLessThan(play.frame.maxY, stick.frame.minY)
        XCTAssertLessThan(volume.frame.maxY, stick.frame.minY)
        XCTAssertGreaterThan(stick.frame.width, app.windows.firstMatch.frame.width * 0.85)
        XCTAssertFalse(app.navigationBars["Apps"].exists)
        play.tap()
        XCTAssertEqual(log.label, "1:Play or pause")

        selectMode("keyboard", title: "Keyboard")
        XCTAssertTrue(app.buttons["q"].waitForExistence(timeout: 5))
        XCTAssertTrue(play.isHittable)
        XCTAssertTrue(volume.isHittable)
        XCTAssertLessThan(play.frame.maxY, app.buttons["q"].frame.minY)
        play.tap()
    }

    func testTabletopKeyboardKeepsKeysAbovePageSwitcher() throws {
        try requireDuoPosture("tabletop")
        launch(openMode: false, logInput: false, additionalArguments: ["-padMode", "keyboard"])
        let space = app.buttons["Space"]
        XCTAssertTrue(space.waitForExistence(timeout: 5))
        assertKeyboardEditingKeys()
        assertKeyboardAbovePageSwitcher()
        let q = app.buttons["q"]
        let letterRow = q.frame.union(app.buttons["p"].frame)
        XCTAssertGreaterThan(letterRow.width, app.windows.firstMatch.frame.width * 0.85)
        XCTAssertGreaterThanOrEqual(q.frame.height, 43.5)
        let ok = app.buttons["OK"]
        XCTAssertTrue(ok.isHittable)
        XCTAssertGreaterThanOrEqual(ok.frame.width, 70)
        XCTAssertTrue(app.buttons["tabletopTVSelection"].isHittable)
        XCTAssertLessThan(app.buttons["Down"].frame.maxY, letterRow.minY)
        XCTAssertLessThan(app.buttons["Clear"].frame.maxY, letterRow.minY)
        XCTAssertLessThan(app.buttons["Home"].frame.maxY, letterRow.minY)
        XCTAssertFalse(app.buttons["tabletopKeyboardSheet"].exists)
        assertTabletopDirectionPadOnRight(minimumGap: 60)
        XCTAssertLessThan(app.buttons["Play or pause"].frame.maxY, letterRow.minY)
        captureKeyboard("iPhone Duo Tabletop keyboard")
    }

    func testTabletopNavigationStaysBelowTheHingeAcrossModes() throws {
        try requireDuoPosture("tabletop")
        launch(openMode: false, logInput: false, additionalArguments: [
            "-demoLGCursor", "YES", "-padMode", "standard",
        ])
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        let navigation = back.frame.union(app.buttons["Home"].frame)
        XCTAssertLessThan(app.buttons["Volume up"].frame.maxY, navigation.minY)

        for (id, title) in [("keypad", "Number pad"), ("eyesFree", "Eyes-free"),
                            ("cursor", "Cursor"), ("keyboard", "Keyboard"), ("standard", "Directional pad")] {
            selectMode(id, title: title)
            assertTabletopNavigationUnchanged(from: navigation)
            if id == "keyboard" {
                let key = app.buttons["q"]
                XCTAssertTrue(key.isHittable)
                XCTAssertLessThan(navigation.maxY, key.frame.minY)
                captureKeyboard("Duo Tabletop mode bar above the keyboard")
            }
        }
    }

    func testShortTabletopUsesTheKeyboardSheet() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Requires an iPhone simulator.")
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .portrait
        launch(openMode: false, additionalArguments: ["-padMode", "standard", "-demoShortTabletop", "YES"])
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        let navigation = back.frame.union(app.buttons["Home"].frame)
        selectMode("keyboard", title: "Keyboard")
        assertTabletopNavigationUnchanged(from: navigation)

        let typing = app.buttons["tabletopKeyboardSheet"]
        XCTAssertTrue(typing.waitForExistence(timeout: 5))
        XCTAssertTrue(typing.isHittable)
        XCTAssertFalse(app.buttons["Space"].exists)
        for label in ["OK", "Down", "Clear", "Home"] {
            let control = app.buttons[label]
            XCTAssertTrue(control.isHittable)
            XCTAssertLessThan(control.frame.maxY, typing.frame.minY)
        }
        XCTAssertLessThan(typing.frame.maxY, app.buttons["Watch"].frame.minY)
        assertShortTabletopCompanionFits()
        captureKeyboard("Short Tabletop typing action")

        typing.tap()
        let field = app.textFields["Search or type…"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Nature documentaries")
        XCTAssertEqual(field.value as? String, "Nature documentaries")
        XCTAssertTrue(app.buttons["Send text"].isEnabled)
        captureKeyboard("Short Tabletop keyboard sheet")
        app.buttons["Send text"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(typing.isHittable)
        let input = app.staticTexts["demoPadInputLog"]
        XCTAssertEqual(input.label, "1:Nature documentaries")
        app.buttons["Clear"].tap()
        XCTAssertEqual(input.label, "\("Nature documentaries".count + 1):Delete")

        typing.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["Return on TV"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(input.label.hasSuffix(":Enter"))
    }

    func testShortTabletopStacksControlsInANarrowWindow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Requires an iPhone simulator.")
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .portrait
        launch(openMode: false, logInput: false, additionalArguments: [
            "-padMode", "keyboard", "-demoShortTabletop", "YES", "-demoShortTabletopCompanionWidth", "375",
        ])
        XCTAssertTrue(app.buttons["tabletopKeyboardSheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Volume up"].isHittable)
        XCTAssertTrue(app.buttons["Left"].isHittable)
        XCTAssertLessThan(app.buttons["Play or pause"].frame.maxY, app.buttons["Left"].frame.minY)
        assertShortTabletopCompanionFits(width: 375)
    }

    func testShortTabletopSheetCarriesAndSubmitsTheBufferedDraft() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone &&
                          ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] != "iPhone19,4",
                          "Requires a rotating iPhone simulator.")
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original.isValidInterfaceOrientation ? original : .portrait }
        device.orientation = .landscapeRight
        launch(openMode: false, additionalArguments: [
            "-padMode", "keyboard", "-demoShortTabletop", "YES", "-demoBufferedKeyboard", "YES",
        ])
        let q = app.buttons["q"]
        XCTAssertTrue(q.waitForExistence(timeout: 5))
        q.tap()
        app.buttons["w"].tap()

        device.orientation = .portrait
        let typing = app.buttons["tabletopKeyboardSheet"]
        XCTAssertTrue(typing.waitForExistence(timeout: 5))
        typing.tap()
        let field = app.textFields["Search or type…"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "qw")
        field.typeText("e")
        XCTAssertEqual(field.value as? String, "qwe")
        app.buttons["Delete draft character"].tap()
        XCTAssertEqual(field.value as? String, "qw")
        field.typeText("e")
        app.buttons["Done"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        typing.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "qwe")
        app.buttons["Send text"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["demoPadInputLog"].label, "3:qwe")
        typing.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send text"].isEnabled)
    }

    private func assertTabletopNavigationUnchanged(from original: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        // Number Pad also exposes a Back key inside its grid.
        let back = app.buttons.matching(identifier: "Back").firstMatch
        let home = app.buttons["Home"]
        XCTAssertTrue(back.isHittable, "Navigation Back is reachable", file: file, line: line)
        XCTAssertTrue(home.isHittable, "Navigation Home is reachable", file: file, line: line)
        let current = back.frame.union(home.frame)
        XCTAssertEqual(current.minX, original.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(current.minY, original.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(current.width, original.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(current.height, original.height, accuracy: 1, file: file, line: line)
    }

    private func assertShortTabletopCompanionFits(width: CGFloat? = nil) {
        let companionWidth = width ?? app.windows.firstMatch.frame.width
        // Two columns require 346 points inside the 20-point margins.
        if companionWidth >= 386 {
            assertTabletopDirectionPadOnRight(minimumGap: 23.5)
        } else {
            XCTAssertLessThan(app.buttons["Play or pause"].frame.maxY, app.buttons["Left"].frame.minY)
            assertClearBelowDPad()
        }
    }

    private func assertTabletopDirectionPadOnRight(minimumGap: CGFloat) {
        let volume = app.buttons["Volume up"]
        let play = app.buttons["Play or pause"]
        XCTAssertTrue(volume.isHittable)
        XCTAssertTrue(play.isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["Left"].frame.minX - volume.frame.maxX, minimumGap)
        XCTAssertLessThan(volume.frame.maxY, play.frame.minY)
        assertClearBelowDPad()
    }

    func testTabletopLGCursorLeavesRoomForTheTouchpad() throws {
        try requireDuoPosture("tabletop")
        launch(openMode: false, additionalArguments: ["-demoLGCursor", "YES", "-padMode", "cursor"])
        let touchpad = app.descendants(matching: .any)["lgCursorTouchpad"].firstMatch
        let settings = app.buttons["lgCursorSettings"]
        let volume = app.buttons["Volume up"]
        XCTAssertTrue(touchpad.waitForExistence(timeout: 5))
        XCTAssertTrue(touchpad.isHittable)
        XCTAssertGreaterThan(touchpad.frame.width, app.windows.firstMatch.frame.width * 0.72)
        XCTAssertTrue(volume.isHittable)
        XCTAssertLessThan(volume.frame.maxY, touchpad.frame.minY)
        XCTAssertEqual(app.buttons.matching(identifier: "Back").count, 1)
        XCTAssertTrue(settings.isHittable)
        let strip = app.descendants(matching: .any).matching(identifier: "Scroll strip").firstMatch
        XCTAssertTrue(strip.isHittable)
        XCTAssertEqual(settings.frame.midX, strip.frame.midX, accuracy: 1)
        XCTAssertLessThan(settings.frame.maxY, strip.frame.minY)
        XCTAssertGreaterThan(strip.frame.minX, touchpad.frame.maxX)
        assertCursorHintInside(touchpad)
        captureKeyboard("Duo Tabletop LG cursor")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Cursor Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Scroll with two fingers or the side strip"].exists)
    }

    private func assertCursorHintInside(_ touchpad: XCUIElement) {
        for line in ["Drag to move · Tap to click", "Scroll with two fingers or the side strip"] {
            let hint = app.staticTexts[line].firstMatch
            XCTAssertTrue(hint.waitForExistence(timeout: 5))
            XCTAssertTrue(touchpad.frame.contains(hint.frame))
        }
    }

    func testTabletopMediaStaysPutWhenTheReportedAppIsMissing() throws {
        try requireDuoPosture("tabletop")
        launch(additionalArguments: ["-demoForegroundAppPackage", "com.google.android.youtube.tv"])
        XCTAssertTrue(app.descendants(matching: .any)["tabletopForegroundApp"].firstMatch.isHittable)
        let volumeWithApp = app.buttons["Volume up"].frame
        let playbackWithApp = app.buttons["Play or pause"].frame
        XCTAssertGreaterThan(volumeWithApp.height, 0)
        XCTAssertGreaterThan(playbackWithApp.height, 0)
        app.terminate()

        launch(additionalArguments: ["-demoForegroundAppPackage", "example.unrecognized"])
        XCTAssertFalse(app.descendants(matching: .any)["tabletopForegroundApp"].firstMatch.exists)
        let volume = app.buttons["Volume up"]
        let playback = app.buttons["Play or pause"]
        XCTAssertTrue(volume.isHittable)
        XCTAssertTrue(playback.isHittable)
        XCTAssertEqual(volume.frame.midY, volumeWithApp.midY, accuracy: 1)
        XCTAssertEqual(playback.frame.midY, playbackWithApp.midY, accuracy: 1)
    }

    func testFoldedVolumeControlsInPortraitAndLandscape() throws {
        try requireDuoPosture("closed")
        let device = XCUIDevice.shared
        let originalOrientation = device.orientation
        defer {
            if originalOrientation.isValidInterfaceOrientation { device.orientation = originalOrientation }
        }
        for orientation: UIDeviceOrientation in [.portrait, .landscapeRight] {
            device.orientation = orientation
            try assertVolumeControlsInGestureModes(isLandscape: orientation.isLandscape)
        }
    }

    func testFlatLandscapeVolumeControlsInGestureModes() throws {
        try requireDuoPosture("flat-landscape")
        try assertVolumeControlsInGestureModes(isLandscape: true)
    }

    func testFlatDuoKeyboardKeepsKeysAbovePageSwitcher() throws {
        try requireDuoPosture("flat-landscape")
        launch(openMode: false, logInput: false, additionalArguments: ["-padMode", "keyboard"])
        let space = app.buttons["Space"]
        XCTAssertTrue(space.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height)
        assertKeyboardEditingKeys()
        assertKeyboardAbovePageSwitcher()
        assertDuoNumberRowAboveLetters()
        let letterRow = app.buttons["q"].frame.union(app.buttons["p"].frame)
        XCTAssertGreaterThan(letterRow.width, 0.80 * window.width)
        XCTAssertLessThan(app.buttons["OK"].frame.maxY, letterRow.minY)
        captureKeyboard("iPhone Duo open landscape keyboard")
    }

    @MainActor
    func testFlatDuoPortraitKeyboardShowsANumberRow() throws {
        try requireDuoPosture("flat-portrait")
        launch(openMode: false, logInput: false, additionalArguments: ["-padMode", "keyboard"])
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.height, window.width)
        assertKeyboardEditingKeys()
        assertKeyboardAbovePageSwitcher()
        assertDuoNumberRowAboveLetters()

        let ok = app.buttons["OK"]
        let clear = app.buttons["Clear"]
        let numberRow = app.buttons["1"].frame.union(app.buttons["0"].frame)
        XCTAssertEqual(ok.frame.midX, numberRow.midX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(ok.frame.width, 94)
        XCTAssertGreaterThan(clear.frame.minX, ok.frame.maxX)
        XCTAssertEqual(clear.frame.midY, ok.frame.midY, accuracy: 1)
        XCTAssertLessThan(app.buttons["Down"].frame.maxY, numberRow.minY)
        captureKeyboard("iPhone Duo open portrait keyboard")
        app.buttons["Shift"].tap()
        try assertHeldCapitalQ(app.buttons["Q"])
        assertDuoNumberRowAboveLetters()

        let space = app.buttons["Space"].frame
        XCTAssertEqual(space.height, 52, accuracy: 1)
        app.buttons["Numbers and symbols"].tap()
        assertDuoLayer(topKey: "1", space: space, capture: "iPhone Duo open portrait numbers")
        app.buttons["More symbols"].tap()
        assertDuoLayer(topKey: "[", space: space, capture: "iPhone Duo open portrait symbols")
    }

    private func assertDuoLayer(topKey: String, space: CGRect, capture: String) {
        let key = app.buttons[topKey]
        XCTAssertTrue(key.isHittable)
        XCTAssertEqual(key.frame.height, space.height, accuracy: 1)
        XCTAssertEqual(app.buttons["Space"].frame.height, space.height, accuracy: 1)
        XCTAssertEqual(app.buttons["Space"].frame.maxY, space.maxY, accuracy: 1)
        captureKeyboard(capture)
    }

    private func assertDuoNumberRowAboveLetters() {
        let firstLetter = app.buttons["q"]
        for digit in "1234567890" {
            let key = app.buttons[String(digit)]
            XCTAssertTrue(key.isHittable, "Number \(digit) should be directly reachable")
            XCTAssertGreaterThanOrEqual(key.frame.height, 43.5)
            XCTAssertLessThan(key.frame.maxY, firstLetter.frame.minY)
        }
    }

    private func assertVolumeControlsInGestureModes(isLandscape: Bool) throws {
        launch()
        try assertVolumeControls(inputLog: log, isLandscape: isLandscape)
        app.terminate()

        launch(openMode: false, additionalArguments: ["-demoLGCursor", "YES", "-padMode", "cursor"])
        XCTAssertTrue(app.descendants(matching: .any)["lgCursorTouchpad"].firstMatch.waitForExistence(timeout: 5))
        try assertVolumeControls(inputLog: app.staticTexts["demoPadInputLog"], isLandscape: isLandscape)
        app.terminate()
    }

    private func assertVolumeControls(inputLog: XCUIElement, isLandscape: Bool) throws {
        let expectedLayout = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = self.app.windows.firstMatch.frame
            return !frame.isEmpty && (isLandscape ? frame.width > frame.height : frame.height > frame.width)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectedLayout], timeout: 5), .completed)
        let increase = app.buttons["Volume up"]
        let decrease = app.buttons["Volume down"]
        let windowFrame = app.windows.firstMatch.frame
        let volumeGroup = increase.frame.union(decrease.frame)
        XCTAssertGreaterThan(volumeGroup.midY, windowFrame.minY + windowFrame.height * 2 / 3)
        for button in [increase, decrease] {
            XCTAssertTrue(button.isHittable)
            let capture = button.screenshot().image
            let bounds = try XCTUnwrap(coloredBounds(in: capture) { red, green, blue in
                green > 120 && Int(green) - Int(red) > 32 && Int(green) - Int(blue) > 18
            }, "Missing visible volume glyph on \(button.label)")
            let aspect = bounds.width * capture.size.width / (bounds.height * capture.size.height)
            // The speaker extends the plus horizontally and adds height to the minus.
            XCTAssertTrue((1.25...2.8).contains(aspect), "Expected a speaker glyph on \(button.label); aspect was \(aspect)")
        }
        increase.tap()
        XCTAssertEqual(inputLog.label, "1:Volume up")
        decrease.tap()
        XCTAssertEqual(inputLog.label, "2:Volume down")
    }

    func testFlatLandscapeEnlargesTheDirectionalPad() throws {
        try requireDuoPosture("flat-landscape")
        launch(openMode: false, additionalArguments: ["-padMode", "standard"])
        let ok = app.buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5))
        // The old 340-point pad cap limited OK to 136 points.
        XCTAssertGreaterThanOrEqual(ok.frame.width, 140)
        XCTAssertTrue(ok.isHittable)
    }

    private func requireDuoPosture(_ posture: String) throws {
        guard ProcessInfo.processInfo.environment["OPEN_REMOTE_DUO_POSTURE"] == posture else {
            throw XCTSkip("Select the Duo posture and set TEST_RUNNER_OPEN_REMOTE_DUO_POSTURE=\(posture) in xcodebuild's environment.")
        }
    }

    func testTVAppsStaysOpenWhenPairingIsRequired() {
        launch(additionalArguments: ["-demoUnpaired", "YES"])
        app.buttons["TV Apps"].tap()
        let youtube = app.buttons["Open YouTube"]
        XCTAssertTrue(youtube.waitForExistence(timeout: 5))
        youtube.tap()
        XCTAssertTrue(app.staticTexts["Pair with your TV to open apps."].waitForExistence(timeout: 5))
        XCTAssertTrue(youtube.exists)
        XCTAssertTrue(app.navigationBars["Apps"].exists)
    }

    func testPowerHoldSendsFullShutdownWithoutAShortPress() {
        launch()
        let power = app.buttons["Power"]
        XCTAssertTrue(power.isHittable)
        power.tap()
        XCTAssertEqual(log.label, "1:Power")
        power.press(forDuration: 1.1)
        XCTAssertEqual(log.label, "2:Turn off")
    }

    func testMovingDuringPowerHoldSendsNoCommand() {
        launch()
        let power = app.buttons["Power"]
        XCTAssertTrue(power.isHittable)
        let center = power.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let moved = center.withOffset(CGVector(dx: 15, dy: 0))
        center.press(forDuration: 0.1, thenDragTo: moved, withVelocity: .default, thenHoldForDuration: 0.8)
        XCTAssertEqual(log.label, "0:None")
        power.tap()
        XCTAssertEqual(log.label, "1:Power")
    }

    func testPairingKeepsTheCodeAndCancelReachableAfterRotation() {
        let device = XCUIDevice.shared
        let originalOrientation = device.orientation
        defer {
            if originalOrientation.isValidInterfaceOrientation { device.orientation = originalOrientation }
        }
        device.orientation = .portrait
        launch(openMode: false, additionalArguments: ["-demoUnpaired", "YES"])
        let startingFrame = app.frame
        app.buttons["Pair"].tap()

        let field = app.textFields["Pairing code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("AB12C")

        device.orientation = .landscapeRight
        waitForLandscapeIfExpected(startingFrame)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isHittable)
        XCTAssertEqual(field.value as? String, "AB12C")
        field.typeText("0")

        let error = app.staticTexts["Incorrect pairing code."]
        let visibleError = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in error.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleError], timeout: 5), .completed)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(app.buttons["Pair"].waitForExistence(timeout: 5))
    }

    func testDownloadedTVArtworkFitsItsGridCell() throws {
        try assertArtworkFitsTiles(size: CGSize(width: 80, height: 125))
        app.terminate()
        try assertArtworkFitsTiles(size: CGSize(width: 175, height: 42))
    }

    private func assertArtworkFitsTiles(size: CGSize) throws {
        let artwork = UIGraphicsImageRenderer(size: size).pngData { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.blue.setFill()
            context.fill(rect)
            UIColor.systemYellow.setFill()
            context.fill(rect.insetBy(dx: size.width * 0.25, dy: size.height * 0.16))
        }
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-jellyfin.enabled", "NO", "-page", "0", "-demoSheet", "apps",
                               "-demoAppArtworkURL", "data:image/png;base64,\(artwork.base64EncodedString())"]
        app.launch()

        let first = app.buttons["Open Artwork 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let tiles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open Artwork ")).allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(tiles.count, 3)
        XCTAssertEqual(first.frame.height, 72, accuracy: 1)
        for (index, tile) in tiles.enumerated() {
            for neighbor in tiles.dropFirst(index + 1) {
                XCTAssertFalse(tile.frame.intersects(neighbor.frame))
            }
        }
        let artworkLoaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.blueArtworkBounds(in: first.screenshot().image) != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [artworkLoaded], timeout: 5), .completed)
        for tile in tiles {
            let artwork = try XCTUnwrap(blueArtworkBounds(in: tile.screenshot().image), "Missing artwork in \(tile.label)")
            let frame = tile.frame
            let points = artwork.applying(CGAffineTransform(scaleX: frame.width, y: frame.height))
            let expectedScale = min((frame.width - 16) / size.width, (frame.height - 16) / size.height)
            XCTAssertEqual(points.width, size.width * expectedScale, accuracy: 2)
            XCTAssertEqual(points.height, size.height * expectedScale, accuracy: 2)
            XCTAssertEqual(points.midX, frame.width / 2, accuracy: 2)
            XCTAssertEqual(points.midY, frame.height / 2, accuracy: 2)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "TV Apps with downloaded artwork \(Int(size.width))×\(Int(size.height))"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func blueArtworkBounds(in capture: UIImage) -> CGRect? {
        coloredBounds(in: capture) { $0 < 70 && $1 < 100 && $2 > 180 }
    }

    /// Returns the bounds of matching pixels as fractions of the captured image.
    private func coloredBounds(in capture: UIImage, matching: (UInt8, UInt8, UInt8) -> Bool) -> CGRect? {
        // Draw through UIImage so orientation metadata is applied before measuring pixels.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let oriented = UIGraphicsImageRenderer(size: capture.size, format: format)
            .image { _ in capture.draw(at: .zero) }
        guard let image = oriented.cgImage, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width
        let height = image.height
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: stride,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                              CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    guard matching(bytes[offset], bytes[offset + 1], bytes[offset + 2]) else { continue }
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
                .applying(CGAffineTransform(scaleX: 1 / CGFloat(width), y: 1 / CGFloat(height)))
        }
    }

    func testRotatingKeepsTheRemoteUsable() {
        let device = XCUIDevice.shared
        let originalOrientation = device.orientation
        defer {
            if originalOrientation.isValidInterfaceOrientation { device.orientation = originalOrientation }
        }
        device.orientation = .portrait
        launch()
        let startingFrame = app.frame
        device.orientation = .landscapeRight
        waitForLandscapeIfExpected(startingFrame)
        XCTAssertTrue(app.buttons["TV Apps"].isHittable)
        let home = app.buttons["Home"]
        let stick = self.stick
        let layoutReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            home.isHittable && stick.isHittable && home.frame.midY < stick.frame.midY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [layoutReady], timeout: 5), .completed)
        stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(log.label, "1:OK")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Eyes-free remote after rotation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func waitForLandscapeIfExpected(_ startingFrame: CGRect) {
        // The Duo's inner display can keep a tall app window after a physical rotation.
        guard UIDevice.current.userInterfaceIdiom == .pad ||
              (startingFrame.width < 500 && startingFrame.width < startingFrame.height) else { return }
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.frame.width > self.app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
    }

    private func selectMode(_ id: String, title: String) {
        let inline = app.buttons["remoteMode-" + id]
        let picker = app.buttons["remoteModePicker"]
        let available = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            inline.exists || picker.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 10), .completed)
        if inline.exists {
            inline.tap()
        } else {
            picker.tap()
            app.buttons[title].tap()
        }
    }

    func testTapBackAndHome() {
        launch()
        stick.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertEqual(log.label, "1:OK")
        let largeBack = app.buttons["eyesFreeBack"]
        (largeBack.exists ? largeBack : app.buttons["Back"]).tap()
        XCTAssertEqual(log.label, "2:Back")
        app.buttons["Home"].tap()
        XCTAssertEqual(log.label, "3:Home")
    }

    func testRestingThumbDoesNothing() {
        launch()
        stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 0.65)
        XCTAssertEqual(log.label, "0:None")
    }

    func testFloatingStickRepeatsAndStopsOnLift() {
        launch()
        let start = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7))
        let end = start.withOffset(CGVector(dx: 70, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.9)
        XCTAssertTrue(log.label.hasSuffix(":Right"))
        let afterLift = count
        XCTAssertGreaterThanOrEqual(afterLift, 2)
        let noMore = NSPredicate { [weak self] _, _ in self?.count != afterLift }
        let expectation = XCTNSPredicateExpectation(predicate: noMore, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 0.6), .timedOut)
        XCTAssertTrue(log.label.hasSuffix(":Right"))
    }

    func testDraggingDoesNotSelect() {
        launch()
        let start = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.6))
        let end = start.withOffset(CGVector(dx: 0, dy: -65))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(log.label.hasSuffix(":Up"))
        XCTAssertGreaterThanOrEqual(count, 1)
    }
}
