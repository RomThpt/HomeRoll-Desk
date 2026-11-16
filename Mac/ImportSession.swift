import CryptoKit
import Foundation

/// One immutable destination for an operation; revocation stops its private URLSession.
@MainActor
final class ImportSession {
    let id = UUID()
    let accountID: String
    let client: ImmichClient
    private(set) var cancelled = false
    private let isAllowed: () -> Bool

    init(accountID: String, client: ImmichClient, isAllowed: @escaping () -> Bool) {
        self.accountID = accountID
        self.client = client
        self.isAllowed = isAllowed
    }

    func check() throws {
        guard !Task.isCancelled, !cancelled, isAllowed() else {
            cancel()
            throw CancellationError()
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        client.cancelRequests()
    }

    static func accountKey(server: URL, userID: String) -> String {
        // Include the server, including its path/port: restored servers can reuse user UUIDs.
        let text = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "\n" + userID
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct MediaReceipt: Codable, Equatable {
    let id: String
    let checksum: String
    let kind: Int
    let liveVideoID: String?
}

struct PhotoReceipt: Codable {
    let revision: String
    let resources: [MediaReceipt]
}

enum ImportFailure: LocalizedError {
    case missingResource, unverifiedMedia, invalidResponse
    var errorDescription: String? {
        switch self {
        case .missingResource: "An original or Live Photo resource is missing. This item will be retried."
        case .unverifiedMedia: "The server copy could not be verified. This item will be retried."
        case .invalidResponse: "The server did not confirm the upload. This item will be retried."
        }
    }
}
