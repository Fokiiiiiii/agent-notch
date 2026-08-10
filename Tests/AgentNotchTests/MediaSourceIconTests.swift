import XCTest
@testable import AgentNotch

/// `mediaSourceIcon(forBundleIdentifier:)` maps a now-playing source to the
/// SF Symbol shown ahead of the track title. Pure `String` in / `String`
/// out, so it's exercised directly here — same pattern as
/// `centeredWeekStrip` and `NotchWindowController.computeClosedSize`.
final class MediaSourceIconTests: XCTestCase {
    func testSpokenAudioSourcesGetTheMicGlyph() {
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "com.apple.podcasts"), "mic.fill")
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "com.overcast.osx"), "mic.fill")
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "au.com.shiftyjelly.pocketcasts"), "mic.fill")
    }

    func testVideoAndBrowserSourcesGetTheScreenGlyph() {
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "com.apple.Safari"), "play.rectangle.fill")
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "com.brave.Browser"), "play.rectangle.fill")
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "com.google.Chrome"), "play.rectangle.fill")
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "org.videolan.vlc"), "play.rectangle.fill")
    }

    func testMusicSourcesFallBackToTheNoteGlyph() {
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "com.apple.Music"), "music.note")
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "com.spotify.client"), "music.note")
    }

    /// An unknown or absent source must still render something rather than
    /// leaving an empty slot where the glyph goes.
    func testUnknownAndMissingIdentifiersFallBackToTheNoteGlyph() {
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "com.example.unknown-player"), "music.note")
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: nil), "music.note")
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: ""), "music.note")
    }

    /// Bundle ids are matched case-insensitively — vendors are inconsistent
    /// about capitalization ("com.apple.Podcasts" vs "com.apple.podcasts").
    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "com.apple.Podcasts"), "mic.fill")
        XCTAssertEqual(mediaSourceIcon(forBundleIdentifier: "COM.BRAVE.BROWSER"), "play.rectangle.fill")
    }
}
