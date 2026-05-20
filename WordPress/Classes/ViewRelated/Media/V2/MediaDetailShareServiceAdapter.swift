import Foundation
import UniformTypeIdentifiers
import WordPressData
import WordPressMediaLibrary

@MainActor
final class MediaDetailShareServiceAdapter: MediaDetailShareService {
    private let blog: Blog
    private let authenticator: MediaRequestAuthenticator

    init(
        blog: Blog,
        authenticator: MediaRequestAuthenticator = MediaRequestAuthenticator()
    ) {
        self.blog = blog
        self.authenticator = authenticator
    }

    func downloadForSharing(items: [DownloadableMediaItem]) async throws -> BulkShareDownloadResult {
        guard !items.isEmpty else {
            return BulkShareDownloadResult(urls: [], cleanup: nil)
        }

        let batchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)

        var usedNames: Set<String> = []
        var result: [URL] = []
        do {
            for item in items {
                try Task.checkCancellation()
                let request = try await authenticator.authenticatedRequest(for: item.sourceUrl, host: MediaHost(blog))
                try Task.checkCancellation()
                let (downloadedURL, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    // URLSession.download wrote a temp file before we knew the
                    // response code. Clean it up so we don't leak.
                    try? FileManager.default.removeItem(at: downloadedURL)
                    throw URLError(.badServerResponse)
                }

                let filename = Self.uniqueFilename(for: item, against: usedNames)
                usedNames.insert(filename)
                let destination = batchDir.appendingPathComponent(filename)
                do {
                    try FileManager.default.moveItem(at: downloadedURL, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: downloadedURL)
                    throw error
                }
                result.append(destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: batchDir)
            throw error
        }
        // Cleanup ownership is explicit: the closure captures the batch
        // directory the adapter just created. SharePayload invokes it on
        // activity-sheet dismissal or selection-mode exit; no caller infers
        // ownership from URL paths.
        return BulkShareDownloadResult(
            urls: result,
            cleanup: { try? FileManager.default.removeItem(at: batchDir) }
        )
    }

    static func uniqueFilename(for item: DownloadableMediaItem, against used: Set<String>) -> String {
        let base = resolveFilename(for: item)
        let usedNames = Set(used.map { $0.lowercased() })
        if !usedNames.contains(base.lowercased()) {
            return base
        }

        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            if !usedNames.contains(candidate.lowercased()) {
                return candidate
            }
            counter += 1
        }
    }

    /// Filename derivation (design § Filename derivation):
    /// 1. Start with `suggestedFilename ?? sourceUrl.lastPathComponent`
    /// 2. Sanitize: trim whitespace, replace `/` with `-`, truncate to 200 chars,
    ///    then reject empty / `.` / `..` components (fall back to "media").
    ///    The module-level helper already screens user-controlled title/slug,
    ///    but this is the final filesystem boundary so it screens the
    ///    URL-last-component fallback path too.
    /// 3. If no extension, derive from `mimeType` via
    ///    `UTType(mimeType:).preferredFilenameExtension`.
    static func resolveFilename(for item: DownloadableMediaItem) -> String {
        var name = item.suggestedFilename ?? item.sourceUrl.lastPathComponent
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "-")
        if name.count > 200 { name = String(name.prefix(200)) }
        if name.isEmpty || name == "." || name == ".." {
            name = "media"
        }
        let ext = (name as NSString).pathExtension
        if ext.isEmpty, let mime = item.mimeType, let resolved = UTType(mimeType: mime)?.preferredFilenameExtension {
            name = "\(name).\(resolved)"
        }
        return name
    }
}
