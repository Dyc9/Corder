import XCTest
@testable import Corder

final class MicReplacementTests: XCTestCase {
    private func device(_ uid: String, _ name: String, _ transport: String) -> AudioInputDevices.Info {
        AudioInputDevices.Info(uid: uid, name: name, manufacturer: nil,
                               transport: transport, isSystemDefault: false)
    }

    func test_closedLid_excludesBuiltInButKeepsUSB() {
        let builtIn = device("builtin", "MacBook Pro Microphone", "BuiltIn")
        let usb = device("usb", "Display Microphone", "USB")
        XCTAssertEqual(AudioInputDevices.pickWiredReplacement(
            candidates: [builtIn, usb], defaultIsBluetooth: true, clamshellClosed: true)?.uid, "usb")
        XCTAssertNil(AudioInputDevices.pickWiredReplacement(
            candidates: [builtIn], defaultIsBluetooth: true, clamshellClosed: true))
    }

    func test_openLid_prefersBuiltInThenUSBMicrophone() {
        let builtIn = device("builtin", "MacBook Pro Microphone", "BuiltIn")
        let usb = device("usb", "Display Microphone", "USB")
        let otherUSB = device("other", "USB Audio", "USB")
        XCTAssertEqual(AudioInputDevices.pickWiredReplacement(
            candidates: [otherUSB, usb, builtIn], defaultIsBluetooth: true, clamshellClosed: false)?.uid, "builtin")
        XCTAssertEqual(AudioInputDevices.pickWiredReplacement(
            candidates: [otherUSB, usb], defaultIsBluetooth: true, clamshellClosed: false)?.uid, "usb")
    }

    func test_noReplacementForNonBluetoothDefaultOrIneligibleDevices() {
        XCTAssertNil(AudioInputDevices.pickWiredReplacement(
            candidates: [device("usb", "USB Microphone", "USB")],
            defaultIsBluetooth: false, clamshellClosed: false))
        let candidates = ["Bluetooth", "Virtual", "Aggregate", "Continuity"].map { device($0, $0, $0) }
        XCTAssertNil(AudioInputDevices.pickWiredReplacement(
            candidates: candidates, defaultIsBluetooth: true, clamshellClosed: false))
        XCTAssertNil(AudioInputDevices.pickWiredReplacement(
            candidates: [], defaultIsBluetooth: true, clamshellClosed: false))
    }

    func test_digitalSilence_firesOnceAfterTwoSecondsOfBuffers() {
        var detector = InitialDigitalSilenceDetector()
        for _ in 0..<19 {
            XCTAssertFalse(detector.observe(peak: 0, frameCount: 4_800, sampleRate: 48_000))
        }
        XCTAssertTrue(detector.observe(peak: -0.0, frameCount: 4_800, sampleRate: 48_000))
        XCTAssertFalse(detector.observe(peak: 0, frameCount: 96_000, sampleRate: 48_000))
    }

    func test_anyNonzeroSample_permanentlyRulesOutInitialDigitalSilence() {
        for peak in [Float.leastNonzeroMagnitude, 0.000001, 0.5] {
            var detector = InitialDigitalSilenceDetector()
            XCTAssertFalse(detector.observe(peak: 0, frameCount: 24_000, sampleRate: 48_000))
            XCTAssertFalse(detector.observe(peak: peak, frameCount: 1, sampleRate: 48_000))
            XCTAssertFalse(detector.observe(peak: 0, frameCount: 144_000, sampleRate: 48_000))
        }
    }

    func test_emptyBuffers_doNotStartWindowAndNewSessionResetsIt() {
        var detector = InitialDigitalSilenceDetector()
        XCTAssertFalse(detector.observe(peak: 0, frameCount: 0, sampleRate: 48_000))
        XCTAssertFalse(detector.observe(peak: 0, frameCount: 96_000, sampleRate: 0))
        XCTAssertFalse(detector.observe(peak: 1, frameCount: 16_000, sampleRate: 16_000))
        detector = InitialDigitalSilenceDetector()
        XCTAssertFalse(detector.observe(peak: 0, frameCount: 16_000, sampleRate: 16_000))
        XCTAssertTrue(detector.observe(peak: 0, frameCount: 16_000, sampleRate: 16_000))
    }
}
