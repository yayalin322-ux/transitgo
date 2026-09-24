import XCTest
@testable import TransitGo

final class BackendConfigTests: XCTestCase {
    func testAComputerOnTheLocalNetworkIsReachedOverPlainHttpWithItsPort() {
        // the exact value the phone build uses: this was https before the fix, so the app could not reach the Mac at all
        XCTAssertEqual(BackendConfig.url(forHost: "MacBook-Neo-2.local:8787")?.absoluteString, "http://MacBook-Neo-2.local:8787")
        XCTAssertEqual(BackendConfig.url(forHost: "192.168.1.117:8787")?.absoluteString, "http://192.168.1.117:8787")
        XCTAssertEqual(BackendConfig.url(forHost: "localhost:4600")?.absoluteString, "http://localhost:4600")
        XCTAssertEqual(BackendConfig.url(forHost: "10.0.0.5:8787")?.absoluteString, "http://10.0.0.5:8787")
        XCTAssertEqual(BackendConfig.url(forHost: "172.20.1.9:8787")?.absoluteString, "http://172.20.1.9:8787")
        XCTAssertEqual(BackendConfig.url(forHost: "127.0.0.1:8787")?.absoluteString, "http://127.0.0.1:8787")
    }

    func testAnyOtherHostIsHttps() {
        XCTAssertEqual(BackendConfig.url(forHost: "transitgo-server.onrender.com")?.absoluteString, "https://transitgo-server.onrender.com")
        XCTAssertEqual(BackendConfig.url(forHost: "abc-def.trycloudflare.com")?.absoluteString, "https://abc-def.trycloudflare.com")
        XCTAssertEqual(BackendConfig.url(forHost: "172.32.0.1")?.absoluteString, "https://172.32.0.1", "172.32 is outside the private range")
        XCTAssertEqual(BackendConfig.url(forHost: "192.169.1.1")?.absoluteString, "https://192.169.1.1")
        XCTAssertEqual(BackendConfig.url(forHost: "notlocal.example.com:443")?.absoluteString, "https://notlocal.example.com:443")
    }

    func testAFullUrlIsUsedAsWritten() {
        XCTAssertEqual(BackendConfig.url(forHost: "http://example.com:81")?.absoluteString, "http://example.com:81")
        XCTAssertEqual(BackendConfig.url(forHost: "https://example.com")?.absoluteString, "https://example.com")
    }

    func testEmptyOrUnsubstitutedHostMeansNoBackend() {
        XCTAssertNil(BackendConfig.url(forHost: ""))
        XCTAssertNil(BackendConfig.url(forHost: "   "))
        XCTAssertNil(BackendConfig.url(forHost: "$(BACKEND_HOST)"))
    }
}
