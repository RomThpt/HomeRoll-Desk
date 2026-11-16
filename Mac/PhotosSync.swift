import Foundation
import Photos
import UniformTypeIdentifiers

/// Übernimmt neue Fotos aus Apples Fotos-App des Macs ins Mac-Konto (nie ins iPhone-Konto).
/// Gleiche Kennung wie der erste Import (tools/mac-import): deviceAssetId „mac-fotos-<UUID>“, Duplikate erkennt der
/// Server per SHA1. Erledigte Objekte merkt sich die App je Konto, damit spätere Abgleiche nur Neues anfassen.
/// Erst nach „Erlauben“ durch den Nutzer (Fotos-Zugriff); läuft danach bei jedem Start und wenn sich die Mediathek ändert.
@MainActor @Observable
final class PhotosSync: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotosSync()
    private(set) var running = false
    var auto: Bool = UserDefaults.standard.bool(forKey: "mac.photosSync.auto") {
        didSet {
            UserDefaults.standard.set(auto, forKey: "mac.photosSync.auto")
            if auto { Task { await run(automatic: true) } } else { stop() }
        }
    }
    @ObservationIgnored private var activeImport: ImportSession?
    @ObservationIgnored private var epoch = UUID()

    /// Revoke network work and delayed resumes. PhotoKit extraction can finish locally, but cannot upload afterward.
    func stop() {
        epoch = UUID()
        activeImport?.cancel()
        pending?.cancel()
        pending = nil
        retry?.cancel()
        retry = nil
        resumeTimer?.cancel()
        resumeTimer = nil
    }

    private var observing = false
    private var pending: Task<Void, Never>?

    // Fortschritt für die Fußzeile der Mediathek (LibraryFooter)
    /// Objekte, die dieser (bzw. der letzte) Abgleich anfassen will, und wie viele davon schon bearbeitet sind
    private(set) var total = 0
    private(set) var finished = 0
    /// davon neu hochgeladen / schon am Server / fehlgeschlagen
    private(set) var uploaded = 0
    private(set) var skipped = 0
    private(set) var failed = 0
    /// Abgleich lief nicht (z. B. kein Fotozugriff) – Grund für „Try Again“
    private(set) var lastError: String?
    /// Fehler des letzten fehlgeschlagenen Objekts (nur für die Details)
    private(set) var lastFailure: String?
    /// Server nicht erreichbar → Abgleich angehalten, läuft von selbst weiter, sobald er wieder antwortet
    private(set) var offline = false
    /// Ende des letzten vollständigen Abgleichs (je Konto gemerkt)
    private(set) var lastRun: Date?
    /// Wie bei iCloud-Fotos: einen Tag pausieren (oder bis „Resume“)
    private(set) var pausedUntil = UserDefaults.standard.object(forKey: "mac.photosSync.pausedUntil") as? Date
    var paused: Bool { pausedUntil.map { $0 > Date() } ?? false }
    /// Rest des laufenden bzw. pausierten Abgleichs
    var remaining: Int { max(0, total - finished) }
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var resumeTimer: Task<Void, Never>?
    @ObservationIgnored private var lastRunAccount: String?
    #if DEBUG
        /// Selbsttest: „Abgleich an/aus“ zeigen, ohne `auto` zu setzen (das würde run() und die Fotos-Abfrage auslösen)
        private var simAuto: Bool?
        /// Selbsttest läuft → nie auf Apples Fotos-Mediathek zugreifen (Zustände nur per `simulate`)
        private static let selfTest = ProcessInfo.processInfo.environment["FOTOS_SELFTEST"] != nil
    #endif

    /// Für die Anzeige: Abgleich eingeschaltet?
    var autoOn: Bool {
        #if DEBUG
            if let simAuto { return simAuto }
        #endif
        return auto
    }

    private var lastRunKey: String { "mac.photosSync.lastRun.v2.\(AccountStore.shared.currentID ?? "-")" }

    private static func receiptKey(_ account: String) -> String { "mac.photosSync.receipts.v2.\(account)" }

    private static func loadReceipts(_ account: String) -> [String: PhotoReceipt] {
        guard let data = UserDefaults.standard.data(forKey: receiptKey(account)) else { return [:] }
        return (try? JSONDecoder().decode([String: PhotoReceipt].self, from: data)) ?? [:]
    }

    private static func saveReceipts(_ receipts: [String: PhotoReceipt], account: String) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(receipts), forKey: receiptKey(account))
    }

    /// Letzten Abgleich des gerade gezeigten Kontos holen (nach Kontowechsel).
    func refreshLastRun() {
        let id = AccountStore.shared.currentID
        guard id != lastRunAccount else { return }
        lastRunAccount = id
        lastRun = UserDefaults.standard.object(forKey: lastRunKey) as? Date
        if !running {
            total = 0
            finished = 0
            uploaded = 0
            skipped = 0
            failed = 0
            lastError = nil
            lastFailure = nil
        }
    }

    /// Beim Start: nur wenn eingeschaltet und Zugriff schon erlaubt (keine Abfrage ohne Klick des Nutzers).
    func startIfEnabled() {
        refreshLastRun()
        if let until = pausedUntil, until > Date() { scheduleResume(until) }
        #if DEBUG
            if Self.selfTest { return }
        #endif
        guard auto, !paused, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        Task { await run(automatic: true) }
    }

    /// Pausieren: das gerade laufende Objekt wird noch fertig, danach hält der Abgleich an (24 h oder bis Fortsetzen).
    func pause(for seconds: TimeInterval = 24 * 3600) {
        let until = Date(timeIntervalSinceNow: seconds)
        pausedUntil = until
        UserDefaults.standard.set(until, forKey: "mac.photosSync.pausedUntil")
        stop()
        scheduleResume(until)
    }

    func resume() {
        clearPause()
        // nur weitermachen, wenn es etwas fortzusetzen gibt (eingeschaltet oder abgebrochener Lauf)
        if autoOn || remaining > 0 { Task { await run() } }
    }

    private func clearPause() {
        pausedUntil = nil
        UserDefaults.standard.removeObject(forKey: "mac.photosSync.pausedUntil")
        resumeTimer?.cancel()
        resumeTimer = nil
    }

    private func scheduleResume(_ until: Date) {
        resumeTimer?.cancel()
        resumeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.pausedUntil == until else { return }
            self.resume()
        }
    }

    func run(automatic: Bool = false) async {
        let lib = Library.shared
        guard !running, !automatic || (auto && !paused) else { return }
        guard let context = try? AccountStore.shared.beginImport() else {
            lib.status = "Choose an account enabled for imports before syncing"
            return
        }
        #if DEBUG
            if Self.selfTest {
                AccountStore.shared.endImport(context)
                return
            }
        #endif
        running = true
        activeImport = context
        defer {
            AccountStore.shared.endImport(context)
            activeImport = nil
            running = false
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard (try? context.check()) != nil else { return }
        guard status == .authorized || status == .limited else {
            lastError = "Photos access has not been granted"
            lib.error = lastError
            return
        }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        if !automatic, paused { clearPause() }
        refreshLastRun()
        lastError = nil
        lastFailure = nil
        offline = false
        total = 0
        finished = 0
        uploaded = 0
        skipped = 0
        failed = 0
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: opts)
        var todo: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in todo.append(asset) }
        total = todo.count
        var receipts = Self.loadReceipts(context.accountID)
        for (i, asset) in todo.enumerated() {
            do {
                try context.check()
                guard !paused, !automatic || auto else { throw CancellationError() }
                lib.status = "Verifying and importing \(i + 1) of \(todo.count)…"
                let resources = PHAssetResource.assetResources(for: asset)
                let revision = Self.revision(asset, resources: resources)
                let key = Self.uuid(asset)
                if let old = receipts[key], old.revision == revision, !old.resources.isEmpty {
                    var valid = true
                    for receipt in old.resources {
                        try context.check()
                        do { try await context.client.verify(receipt) } catch {
                            valid = false
                            break
                        }
                    }
                    try context.check()
                    if valid {
                        skipped += 1
                        finished += 1
                        continue
                    }
                }
                // Remove stale success before retrying: interrupted/partial uploads never become completed receipts.
                receipts.removeValue(forKey: key)
                try Self.saveReceipts(receipts, account: context.accountID)
                let uploadedResources = try await upload(asset, resources: resources, context: context)
                try context.check()
                receipts[key] = PhotoReceipt(revision: revision, resources: uploadedResources)
                try Self.saveReceipts(receipts, account: context.accountID)
                uploaded += 1
            } catch {
                if context.cancelled || error is CancellationError {
                    lib.status = "Sync stopped; unfinished items will be checked again"
                    return
                }
                failed += 1
                lastFailure = error.localizedDescription
                if Library.isConnectionError(error) {
                    offline = true
                    lib.status = "Offline; unfinished items remain pending"
                    if automatic { waitForServer(account: context.accountID) }
                    return
                }
            }
            finished += 1
        }
        try? context.check()
        guard !context.cancelled else { return }
        lib.status = "Photos: \(uploaded) imported, \(skipped) verified, \(failed) pending"
        if failed == 0 {
            lastRun = Date()
            UserDefaults.standard.set(lastRun, forKey: "mac.photosSync.lastRun.v2.\(context.accountID)")
        }
        if uploaded > 0 { await lib.load() }
    }

    static func serverReachable() async -> Bool {
        guard let client = try? ImmichClient.shared.scopedClient() else { return false }
        defer { client.cancelRequests() }
        guard let data = try? await client.raw("server/ping", auth: false) else { return false }
        return String(data: data, encoding: .utf8)?.contains("pong") == true
    }

    private func waitForServer(account: String) {
        retry?.cancel()
        let generation = epoch
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.epoch == generation,
                self.auto, !self.paused, AccountStore.shared.currentID == account
            else { return }
            self.retry = nil
            await self.run(automatic: true)
        }
    }

    #if DEBUG
        /// Selbsttest: Zustände der Fußzeile nachstellen, ohne Fotozugriff und ohne etwas hochzuladen.
        /// nil = wieder echter Zustand.
        func simulate(_ s: String?) {
            simAuto = nil
            offline = false
            lastError = nil
            lastFailure = nil
            running = false
            total = 0
            finished = 0
            uploaded = 0
            skipped = 0
            failed = 0
            pausedUntil = UserDefaults.standard.object(forKey: "mac.photosSync.pausedUntil") as? Date
            lastRun = UserDefaults.standard.object(forKey: lastRunKey) as? Date
            guard let s else { return }
            simAuto = true
            lastRun = Date(timeIntervalSinceNow: -300)
            switch s {
            case "searching": running = true
            case "running":
                running = true
                total = 988
                finished = 312
                uploaded = 300
                skipped = 12
            case "paused":
                total = 988
                finished = 312
                pausedUntil = Date(timeIntervalSinceNow: 3600)
            case "error": lastError = "No access to the Photos library"
            case "partial":
                total = 40
                finished = 40
                uploaded = 37
                failed = 3
                lastFailure = "The file couldn’t be read."
            case "offline":
                total = 988
                finished = 312
                offline = true
            case "off":
                simAuto = false
                lastRun = nil
            case "never": lastRun = nil
            default:
                total = 12
                finished = 12
                uploaded = 5
                skipped = 7
            }
        }
    #endif

    nonisolated static func uuid(_ a: PHAsset) -> String {
        String(a.localIdentifier.split(separator: "/").first ?? Substring(a.localIdentifier))
    }

    /// Stable revision changes when Photos edits a resource or changes metadata.
    private static func revision(_ asset: PHAsset, resources: [PHAssetResource]) -> String {
        let names = resources.map { "\($0.type.rawValue):\($0.originalFilename)" }.sorted().joined(separator: "|")
        return "\(asset.modificationDate?.timeIntervalSince1970 ?? 0)|\(asset.isFavorite)|\(asset.isHidden)|\(names)"
    }

    static func resourceOrder(types: [PHAssetResourceType], video: Bool, live: Bool) throws -> [Int] {
        guard types.contains(video ? .video : .photo), !live || types.contains(.pairedVideo) else {
            throw ImportFailure.missingResource
        }
        let media: Set<PHAssetResourceType> = [
            .photo, .video, .pairedVideo, .fullSizePhoto, .fullSizeVideo,
            .fullSizePairedVideo, .alternatePhoto, .adjustmentBasePhoto, .adjustmentBasePairedVideo, .adjustmentBaseVideo,
        ]
        guard types.allSatisfy({ media.contains($0) || $0 == .adjustmentData }) else { throw ImportFailure.missingResource }
        // Proprietary adjustment recipes are not media; keep original plus rendered edits instead.
        return types.indices.filter { media.contains(types[$0]) }.sorted {
            let left = types[$0] == .pairedVideo || types[$0] == .fullSizePairedVideo
            let right = types[$1] == .pairedVideo || types[$1] == .fullSizePairedVideo
            return left == right ? $0 < $1 : left
        }
    }

    private func upload(_ asset: PHAsset, resources: [PHAssetResource], context: ImportSession) async throws -> [MediaReceipt] {
        let order = try Self.resourceOrder(
            types: resources.map(\.type), video: asset.mediaType == .video,
            live: asset.mediaSubtypes.contains(.photoLive))
        var receipts: [MediaReceipt] = []
        for index in order {
            try context.check()
            let resource = resources[index]
            let pairedType: PHAssetResourceType? = resource.type == .photo ? .pairedVideo : resource.type == .fullSizePhoto ? .fullSizePairedVideo : nil
            let videoID = pairedType.flatMap { type in receipts.first(where: { $0.kind == type.rawValue })?.id }
            let receipt = try await send(resource, asset: asset, liveVideoID: videoID, context: context)
            receipts.append(receipt)
        }
        guard !receipts.isEmpty else { throw ImportFailure.missingResource }
        return receipts
    }

    private func send(_ resource: PHAssetResource, asset: PHAsset, liveVideoID: String?, context: ImportSession) async throws -> MediaReceipt {
        try context.check()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("homeroll-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        try context.check()
        let sha1 = try await Task.detached { try Transfer.sha1Hex(file) }.value
        try context.check()
        let api = context.client
        let deviceID = "mac-fotos-\(Self.uuid(asset))-\(resource.type.rawValue)-\(sha1)"
        let existing = try await api.bulkUploadCheck(id: deviceID, checksum: sha1)
        try context.check()
        let id: String
        if let existing {
            id = existing
        } else {
            let iso = ISO8601DateFormatter()
            var fields = [
                "fileCreatedAt": iso.string(from: asset.creationDate ?? Date()),
                "fileModifiedAt": iso.string(from: asset.modificationDate ?? asset.creationDate ?? Date()),
                "filename": resource.originalFilename, "deviceAssetId": deviceID, "deviceId": "HomeRoll-Desktop-Local",
                "isFavorite": asset.isFavorite ? "true" : "false",
            ]
            if let liveVideoID { fields["livePhotoVideoId"] = liveVideoID }
            if asset.isHidden { fields["visibility"] = "archive" }
            let result = try await api.uploadAsset(
                file: file, filename: resource.originalFilename, uti: resource.uniformTypeIdentifier,
                fields: fields, checksum: sha1, expensive: true)
            try context.check()
            guard ["created", "duplicate"].contains(result.status), !result.id.isEmpty else { throw ImportFailure.invalidResponse }
            id = result.id
        }
        if let liveVideoID {
            try context.check()
            try await api.raw("assets/\(id)", method: "PUT", body: api.json(["livePhotoVideoId": liveVideoID]))
            try context.check()
        }
        let receipt = MediaReceipt(id: id, checksum: sha1, kind: resource.type.rawValue, liveVideoID: liveVideoID)
        try await api.verify(receipt)
        try context.check()
        return receipt
    }

    // Neue Fotos in Apples Fotos-App → kurz warten (Import läuft oft in Schüben), dann abgleichen
    nonisolated func photoLibraryDidChange(_ change: PHChange) {
        Task { @MainActor in
            guard self.auto, !self.paused else { return }
            self.pending?.cancel()
            let generation = self.epoch
            self.pending = Task {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, self.epoch == generation, self.auto, !self.paused else { return }
                await self.run(automatic: true)
            }
        }
    }
}
