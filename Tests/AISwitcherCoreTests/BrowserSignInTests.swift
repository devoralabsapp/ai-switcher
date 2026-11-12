import XCTest
@testable import AISwitcherCore

final class BrowserSignInTests: XCTestCase {
    func testNativeLoginURLKeepsItsStateAndLocalCallback() throws {
        let value = "https://accounts.google.com/o/oauth2/v2/auth?state=fixture&redirect_uri=http%3A%2F%2F127.0.0.1%3A53743%2Foauth-callback"
        XCTAssertEqual(try BrowserSignIn.antigravityURL(from: BrowserSignIn.antigravityURLPrefix + value)?.absoluteString, value)
        XCTAssertNil(try BrowserSignIn.antigravityURL(from: "Listening on localhost"))
        for invalid in [
            value.replacingOccurrences(of: "https:", with: "http:"),
            value.replacingOccurrences(of: "accounts.google.com", with: "accounts.google.com.example.test"),
            value.replacingOccurrences(of: "state=fixture", with: "state="),
            value.replacingOccurrences(of: "127.0.0.1", with: "example.test"),
            value.replacingOccurrences(of: "accounts.google.com", with: "user@accounts.google.com"),
            value.replacingOccurrences(of: "53743", with: "80")
        ] {
            XCTAssertThrowsError(try BrowserSignIn.antigravityURL(from: BrowserSignIn.antigravityURLPrefix + invalid))
        }
    }
}
