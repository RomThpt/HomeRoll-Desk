import CryptoKit
import Photos
import XCTest

@testable import HomeRollDesktop

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let callback = Self.lock.withLock {
                Self.requests.append(request)
                return Self.handler
            }
            let (status, body) = try callback!(request)
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class SafetyTests: XCTestCase {
    private func client(_ host: String = "a.invalid") -> ImmichClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = ImmichClient(configuration: config)
        client.activate(server: URL(string: "https://\(host)")!, token: "dummy-\(host)")
        StubProtocol.lock.withLock {
            StubProtocol.requests = []
            StubProtocol.handler = nil
        }
        return client
    }

    func testDestinationDoesNotFollowGlobalAccount() async throws {
        let fixed = client()
        let context = ImportSession(accountID: "a", client: fixed, isAllowed: { true })
        ImmichClient.shared.activate(server: URL(string: "https://b.invalid")!, token: "dummy-b")
        StubProtocol.lock.withLock { StubProtocol.handler = { _ in (200, Data("{\"results\":[]}".utf8)) } }
        try context.check()
        _ = try await context.client.bulkUploadCheck(id: "fixture", checksum: "abc")
        let requests = StubProtocol.lock.withLock { StubProtocol.requests }
        XCTAssertEqual(requests.map { $0.url!.host! }, ["a.invalid"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer dummy-a.invalid")
        context.cancel()
        ImmichClient.shared.logout()
    }

    func testRevokedImportNeverReadsOrUploadsFile() async {
        let fixed = client()
        let context = ImportSession(accountID: "a", client: fixed, isAllowed: { true })
        context.cancel()
        do {
            _ = try await Transfer.upload(URL(fileURLWithPath: "/nonexistent-synthetic-fixture"), context: context)
            XCTFail("Cancelled import proceeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(StubProtocol.lock.withLock { StubProtocol.requests.isEmpty })
    }

    func testPermissionRevocationCancelsContext() throws {
        var allowed = true
        let context = ImportSession(accountID: "a", client: client(), isAllowed: { allowed })
        try context.check()
        allowed = false
        XCTAssertThrowsError(try context.check())
        XCTAssertTrue(context.cancelled)
    }

    func testAccountIdentityIncludesServerAndPath() {
        let a = ImportSession.accountKey(server: URL(string: "https://a.invalid")!, userID: "same-user")
        XCTAssertNotEqual(a, ImportSession.accountKey(server: URL(string: "https://b.invalid")!, userID: "same-user"))
        XCTAssertNotEqual(a, ImportSession.accountKey(server: URL(string: "https://a.invalid/other")!, userID: "same-user"))
    }

    func testTokenCannotBeAttachedToForeignOrigin() throws {
        let fixed = client()
        XCTAssertThrowsError(try fixed.authorized(URL(string: "https://b.invalid/photo")!))
        XCTAssertThrowsError(try fixed.authorized(URL(string: "http://a.invalid/photo")!))
        XCTAssertThrowsError(try fixed.authorized(URL(string: "https://a.invalid:8443/photo")!))
        XCTAssertNoThrow(try fixed.authorized(URL(string: "https://a.invalid/api/assets")!))
    }

    func testMissingOriginalOrLiveVideoFailsClosed() {
        XCTAssertThrowsError(try PhotosSync.resourceOrder(types: [], video: false, live: false))
        XCTAssertThrowsError(try PhotosSync.resourceOrder(types: [.fullSizePhoto], video: false, live: false))
        XCTAssertThrowsError(try PhotosSync.resourceOrder(types: [.photo], video: false, live: true))
    }

    func testLivePhotoAndRenderedResourcesAreIncluded() throws {
        let types: [PHAssetResourceType] = [.photo, .fullSizePhoto, .pairedVideo, .fullSizePairedVideo, .adjustmentData, .alternatePhoto]
        let order = try PhotosSync.resourceOrder(types: types, video: false, live: true)
        XCTAssertEqual(Set(order), Set([0, 1, 2, 3, 5]))
        XCTAssertLessThan(order.firstIndex(of: 2)!, order.firstIndex(of: 0)!)
        XCTAssertLessThan(order.firstIndex(of: 3)!, order.firstIndex(of: 1)!)
    }

    func testReceiptRejectsWrongMissingChecksumTrashAndMissingLivePair() async throws {
        let fixed = client()
        let receipt = MediaReceipt(id: "fixture", checksum: String(repeating: "00", count: 20), kind: 1, liveVideoID: "paired")
        for extra in ["", ",\"checksum\":\"bad\"", ",\"checksum\":\"\(receipt.checksum)\",\"isTrashed\":true", ",\"checksum\":\"\(receipt.checksum)\""] {
            let data = Data("{\"id\":\"fixture\"\(extra)}".utf8)
            StubProtocol.lock.withLock { StubProtocol.handler = { _ in (200, data) } }
            do {
                try await fixed.verify(receipt)
                XCTFail("Invalid receipt accepted")
            } catch {}
        }
    }

    func testReceiptAcceptsMatchingChecksumAndLivePair() async throws {
        let fixed = client()
        let checksum = String(repeating: "00", count: 20)
        let data = Data(
            "{\"id\":\"fixture\",\"checksum\":\"\(Data(repeating: 0, count: 20).base64EncodedString())\",\"isTrashed\":false,\"livePhotoVideoId\":\"paired\"}"
                .utf8)
        StubProtocol.lock.withLock { StubProtocol.handler = { _ in (200, data) } }
        try await fixed.verify(MediaReceipt(id: "fixture", checksum: checksum, kind: 1, liveVideoID: "paired"))
    }

    func testFileUploadStaysOnCapturedServerAcrossAccountSwitch() async throws {
        let fixed = client()
        let context = ImportSession(accountID: "a", client: fixed, isAllowed: { true })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("homeroll-test-" + UUID().uuidString)
        let data = Data("synthetic photo fixture".utf8)
        try data.write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            context.cancel()
            ImmichClient.shared.logout()
        }
        let checksum = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        StubProtocol.lock.withLock {
            StubProtocol.handler = { request in
                let result: String
                if request.url!.path.hasSuffix("bulk-upload-check") {
                    ImmichClient.shared.activate(server: URL(string: "https://b.invalid")!, token: "dummy-b")
                    result = "{\"results\":[]}"
                } else if request.httpMethod == "POST" {
                    result = "{\"id\":\"fixture\",\"status\":\"created\"}"
                } else {
                    result = "{\"id\":\"fixture\",\"checksum\":\"\(checksum)\",\"isTrashed\":false}"
                }
                return (200, Data(result.utf8))
            }
        }
        let uploaded = try await Transfer.upload(file, context: context)
        XCTAssertTrue(uploaded)
        let requests = StubProtocol.lock.withLock { StubProtocol.requests }
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.url!.host == "a.invalid" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-a.invalid" })
    }

    func testPermissionChangeDuringDuplicateCheckPreventsUpload() async throws {
        final class Permission: @unchecked Sendable {
            let lock = NSLock()
            var value = true
            func allowed() -> Bool { lock.withLock { value } }
            func revoke() { lock.withLock { value = false } }
        }
        let permission = Permission()
        let fixed = client()
        let context = ImportSession(accountID: "a", client: fixed, isAllowed: { permission.allowed() })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("homeroll-test-" + UUID().uuidString)
        try Data("synthetic fixture".utf8).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            context.cancel()
        }
        StubProtocol.lock.withLock {
            StubProtocol.handler = { _ in
                permission.revoke()
                return (200, Data("{\"results\":[]}".utf8))
            }
        }
        do {
            _ = try await Transfer.upload(file, context: context)
            XCTFail("Upload continued after revocation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let requests = StubProtocol.lock.withLock { StubProtocol.requests }
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].url!.path.hasSuffix("bulk-upload-check"))
    }

}
