import Combine
import Foundation
import OrderedCollections
import SwiftUI
import WordPressAPI
import WordPressAPIInternal
import WordPressCore

/// App-target switches that gate which detail screen affordances are
/// available. Public so app-side routing can populate it without going
/// through the (internal) view model type.
public struct MediaLibraryCapabilities: Equatable, Sendable {
    public let supportsAltEditing: Bool
    public let supportsMetadataEditing: Bool
    public let supportsDeletion: Bool

    public init(
        supportsAltEditing: Bool,
        supportsMetadataEditing: Bool,
        supportsDeletion: Bool
    ) {
        self.supportsAltEditing = supportsAltEditing
        self.supportsMetadataEditing = supportsMetadataEditing
        self.supportsDeletion = supportsDeletion
    }
}

extension MediaLibraryCapabilities {
    /// Test-only default with all three capability flags `true`. Lives
    /// here (not behind `#if DEBUG`) because the test-only initializer
    /// of `MediaLibraryViewModel` is itself compiled unconditionally
    /// and uses this as a default parameter value.
    static let testDefault = MediaLibraryCapabilities(
        supportsAltEditing: true,
        supportsMetadataEditing: true,
        supportsDeletion: true
    )
}

/// Backs a single media grid: the library (no query) or one search query.
/// Owns exactly one collection. The library instance also drives the
/// client-side `kind` filter; the search instance leaves `kind` nil, so its
/// `displayItems` equals `items`.
@MainActor
final class MediaLibraryViewModel: ObservableObject {
    typealias Collection = any MediaMetadataCollectionWithEditContextProtocol

    private let tracker: any MediaTracker
    private let client: WordPressClient
    private let collection: Collection
    let uploader: MediaUploader?
    let urlOpener: (any MediaDetailURLOpener)?
    let shareService: (any MediaDetailShareService)?
    let detailNavigator: (any MediaDetailNavigator)?
    let detailCapabilities: MediaLibraryCapabilities?

    /// Caches the most-recent `MediaWithEditContext` per item id so
    /// `makeDetailVM(for:)` can hand the detail screen a fully-resolved
    /// payload without re-fetching. Rebuilt on every `loadItems` snapshot.
    private var resolvedMediaByID: [Int64: MediaWithEditContext] = [:]

    /// Test-only override for the client-presence half of `canOpenDetail`.
    /// Does not bypass the resolved-payload half: `resolvedMediaByID[id]`
    /// still has to be non-nil. Declared without `#if DEBUG` because
    /// `canOpenDetail` itself is unconditional production code that reads
    /// the property; a DEBUG guard would break non-DEBUG builds.
    var testOverrideHasClient: Bool?

    @Published private(set) var bannerSummary: BannerSummary?
    @Published private(set) var uploadsScreenItems: [UploadRowItem] = []

    private var uploaderObserverTask: Task<Void, Never>?

    struct BannerSummary: Equatable {
        let pendingCount: Int
        let failedCount: Int
    }

    struct UploadRowItem: Identifiable, Equatable {
        enum Mode: Equatable {
            case uploading(Progress)
            case failed(message: String, isRetryable: Bool)
        }
        let id: UUID
        let displayName: String
        let kind: MediaKind
        let localFileURL: URL?
        let mode: Mode
    }

    @Published private(set) var items: [MediaGridItem] = []
    /// Stored, derived from `items` + `kind`. Recomputed only in `reload()` and
    /// `setKind(_:)` so the grid never re-filters during `body` evaluation.
    @Published private(set) var displayItems: [MediaGridItem] = []
    @Published private(set) var kind: MediaKind?
    @Published private(set) var error: Error?
    @Published private(set) var isLoadComplete = false

    // MARK: - Selection state (M5)

    @Published private(set) var isSelectionModeActive: Bool = false

    /// Insertion-ordered set of selected media ids. Read by the view for
    /// badge state, by `selectionToolbarTitle`, and by the bulk-action
    /// methods. Iteration order is consumed by bulk share to preserve the
    /// user's tap order when assembling the activity items.
    @Published private(set) var selectedIDs = OrderedSet<Int64>()

    /// In-flight delete markers, dims + spinners + disables hit testing
    /// on the corresponding cells. Cleared inside `performDelete`'s `defer`
    /// (both success and failure paths) for pagination safety.
    @Published private(set) var pendingDeleteIDs: Set<Int64> = []

    /// Bulk-share state machine. `.preparing` while
    /// `MediaDetailShareService.downloadForSharing(items:)` runs. Reset to
    /// `.idle` on completion, failure, cancellation, or `exitSelectionMode()`.
    @Published private(set) var bulkShareState: BulkShareState = .idle

    /// Identity for the currently-active bulk-share download. The view's
    /// `.task(id: bulkShareRequest?.id)` modifier owns the download task;
    /// flipping the id to nil cancels it cooperatively.
    @Published private(set) var bulkShareRequest: BulkShareRequest?

    /// Activity-sheet payload. Set by `performBulkShare` on success;
    /// presented via `.sheet(item:)`. Nilled in `reportShareDismissed` or
    /// `exitSelectionMode`.
    @Published var sharePayload: MediaDetailViewModel.SharePayload?

    /// Toggle-time payload snapshot, keyed by media id. Survives
    /// `loadItems` rebuilds of `resolvedMediaByID`, so a selection that
    /// spans pages remains shareable after a page-1 refresh. Not
    /// `@Published`; the view never reads it directly. Bulk-share-item
    /// construction reads it.
    private var selectedMediaSnapshots: [Int64: MediaWithEditContext] = [:]

    /// V1 parity title: five variants for empty / image-singular / image-plural
    /// / item-singular / item-plural. Reads `selectedMediaSnapshots` for the
    /// image-vs-mixed decision so the lookup is cheap and survives refresh.
    var selectionToolbarTitle: String {
        let count = selectedIDs.count
        if count == 0 { return Strings.selectionTitleEmpty }
        if allSelectedAreImages {
            let template = count == 1 ? Strings.selectionTitleImageSingular : Strings.selectionTitleImagePlural
            return String.localizedStringWithFormat(template, count)
        }
        let template = count == 1 ? Strings.selectionTitleItemSingular : Strings.selectionTitleItemPlural
        return String.localizedStringWithFormat(template, count)
    }

    private var allSelectedAreImages: Bool {
        guard !selectedIDs.isEmpty else { return false }
        return selectedIDs.allSatisfy { id in
            selectedMediaSnapshots[id]?.mimeType.hasPrefix("image/") == true
        }
    }

    enum BulkShareState: Equatable { case idle, preparing }

    struct BulkShareRequest: Identifiable {
        let id = UUID()
        let items: [DownloadableMediaItem]
    }

    /// Guards re-entrant loads. Safe because each instance owns one collection,
    /// so a skipped re-entrant call never loses a distinct load.
    private var isLoading = false

    /// Pure type-filter, extracted so it can be unit-tested directly with
    /// fixture items (a real collection can't yield known-kind items in tests).
    /// Unknown-kind items (`kind == nil`) match no specific type, so they
    /// appear only under "All".
    static func applyingKindFilter(_ items: [MediaGridItem], kind: MediaKind?) -> [MediaGridItem] {
        guard let kind else { return items }
        return items.filter { $0.kind == kind }
    }

    // MARK: Empty-state / overlay signals

    var shouldDisplayInitialLoading: Bool {
        items.isEmpty && !isLoadComplete && error == nil
    }
    var shouldDisplayEmpty: Bool {
        kind == nil && isLoadComplete && items.isEmpty && error == nil
    }
    var shouldDisplayFilterEmpty: Bool {
        kind != nil && isLoadComplete && displayItems.isEmpty && error == nil
    }
    func errorToDisplay() -> Error? {
        items.isEmpty ? error : nil
    }

    // MARK: Init

    /// Builds the collection from the wordpress-rs service: the library when
    /// `search` is nil, a search collection otherwise. `client` is retained so
    /// `observe()` can subscribe to the local cache's update stream. The
    /// `uploader` and detail wiring are passed only for the library instance;
    /// search instances leave them nil and never surface the upload banner,
    /// the queue, or the cell-tap detail push.
    init(
        service: WpService,
        client: WordPressClient,
        tracker: any MediaTracker,
        search: String? = nil,
        uploader: MediaUploader? = nil,
        urlOpener: (any MediaDetailURLOpener)? = nil,
        shareService: (any MediaDetailShareService)? = nil,
        navigator: (any MediaDetailNavigator)? = nil,
        capabilities: MediaLibraryCapabilities? = nil
    ) {
        self.tracker = tracker
        self.client = client
        self.collection = service.media()
            .createMediaMetadataCollectionWithEditContext(
                filter: MediaListFilter(search: search, mediaType: nil),
                perPage: 100
            )
        self.uploader = uploader
        self.urlOpener = urlOpener
        self.shareService = shareService
        self.detailNavigator = navigator
        self.detailCapabilities = capabilities
        startUploaderObserver()
    }

    /// Subscribes weakly so a navigated-away view model deallocates instead
    /// of being kept alive by the stream loop. The publisher replays the
    /// current snapshot to the new subscriber before emitting transitions.
    private func startUploaderObserver() {
        guard let uploader else { return }
        let publisher = uploader.statePublisher
        uploaderObserverTask = Task { [weak self] in
            for await state in publisher.values {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.applyUploaderState(state)
            }
        }
    }

    deinit {
        uploaderObserverTask?.cancel()
    }

    @MainActor
    private func applyUploaderState(_ state: UploaderState) {
        if state.isEmpty {
            bannerSummary = nil
        } else {
            bannerSummary = BannerSummary(
                pendingCount: state.pendingCount,
                failedCount: state.failedCount
            )
        }
        // `state.entries` preserves submission order across pending/failed
        // transitions, so the Uploads-screen row stays put when an
        // in-flight upload fails (or a failed row is retried).
        uploadsScreenItems = state.entries.map { entry in
            switch entry {
            case .pending(let p):
                return UploadRowItem(
                    id: p.id,
                    displayName: p.displayName,
                    kind: p.kind,
                    localFileURL: p.localFileURL,
                    mode: .uploading(p.progress)
                )
            case .failed(let f):
                return UploadRowItem(
                    id: f.id,
                    displayName: f.displayName,
                    kind: f.kind,
                    localFileURL: f.localFileURL,
                    mode: .failed(message: f.errorMessage, isRetryable: f.isRetryable)
                )
            }
        }
    }

    func enqueue(sources: [UploadSource]) async {
        guard let uploader else { return }
        for source in sources {
            let resolvedSource = analyticsSourceFor(source: source)
            tracker.track(.mediaLibraryAdded(source: resolvedSource, kind: source.estimatedKind))
        }
        await uploader.enqueue(sources: sources)
    }

    func cancelUpload(_ id: UUID) async {
        await uploader?.cancel(id)
    }

    func retryUpload(_ id: UUID) async {
        guard let uploader else { return }
        tracker.track(.mediaLibraryUploadRetried)
        await uploader.retry(id)
    }

    func dismissUpload(_ id: UUID) async {
        await uploader?.dismiss(id)
    }

    func cancelAllUploads() async { await uploader?.cancelAllPending() }

    func retryAllUploads() async {
        guard let uploader else { return }
        let retryable = uploadsScreenItems.contains { row in
            if case .failed(_, let isRetryable) = row.mode { return isRetryable }
            return false
        }
        guard retryable else { return }
        tracker.track(.mediaLibraryUploadRetried)
        await uploader.retryAllFailed()
    }

    func dismissAllUploads() async { await uploader?.dismissAllFailed() }

    private func analyticsSourceFor(source: UploadSource) -> MediaUploadSource {
        switch source {
        case .photoLibrary: return .photoLibrary
        case .cameraImage, .cameraVideo: return .camera
        case .file: return .otherApps
        case .imagePlayground: return .imagePlayground
        case .remoteURL:
            // Stock Photos is the only external picker that produces .remoteURL.
            return .stockPhotos
        }
    }

    // MARK: Filter mutator

    func setKind(_ newKind: MediaKind?) {
        guard kind != newKind else { return }
        if isSelectionModeActive {
            exitSelectionMode()
        }
        withAnimation {
            kind = newKind
            displayItems = Self.applyingKindFilter(items, kind: newKind)
        }
        tracker.track(.mediaLibraryFilterChanged(kind: newKind))
    }

    // MARK: - Selection mode (M5)

    func enterSelectionMode() {
        isSelectionModeActive = true
    }

    func exitSelectionMode() {
        // Reset bulkShareState alongside bulkShareRequest. Without this, a
        // Done tap before SwiftUI enters `.task(id:)`'s body would leave
        // bulkShareState stuck at .preparing. Nils sharePayload too, closes
        // the race where downloads finish and the activity sheet is about
        // to present when the user taps Done.
        bulkShareState = .idle
        bulkShareRequest = nil
        sharePayload = nil
        isSelectionModeActive = false
        selectedIDs.removeAll()
        selectedMediaSnapshots.removeAll()
    }

    /// Toggles the item's id in `selectedIDs` and captures/clears its
    /// payload snapshot in `selectedMediaSnapshots`. No-op for items where
    /// `canOpenDetail` returns false (placeholders, error rows without
    /// cached payload). Reads `resolvedMediaByID[item.id]` for the snapshot
    /// payload at toggle time; that payload then survives subsequent
    /// refreshes / pagination changes that mutate `resolvedMediaByID`.
    func toggleSelection(for item: MediaGridItem) {
        guard canOpenDetail(for: item) else { return }
        guard let media = resolvedMediaByID[item.id] else { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
            selectedMediaSnapshots[item.id] = nil
        } else {
            selectedIDs.append(item.id)
            selectedMediaSnapshots[item.id] = media
        }
    }

    func isSelected(_ item: MediaGridItem) -> Bool {
        selectedIDs.contains(item.id)
    }

    // MARK: Load (eager)

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        error = nil
        isLoadComplete = false

        await reload()
        do {
            var result = try await collection.refresh()
            await reload()
            while collection.hasMorePages() != false {
                if Task.isCancelled { return }
                let previousTotal = result.totalItems
                result = try await collection.loadNextPage()
                await reload()
                if result.hasMorePages == false || result.totalItems <= previousTotal {
                    break
                }
            }
            if !Task.isCancelled {
                isLoadComplete = true
                // Now that every page is loaded, drop any selection that points
                // at an item the server no longer returns (e.g. deleted from
                // another device). reload()'s own reconcile is a no-op until this
                // flag flips, so the final pass has to happen here.
                reconcileSelection()
            }
        } catch {
            if !(error is CancellationError), !Task.isCancelled {
                Loggers.mediaLibrary.error("Media library load failed: \(error)")
                self.error = error
            }
        }
    }

    func refresh() async {
        await load()
    }

    // MARK: Data-change observer

    func observe() async {
        let collection = self.collection
        let batches = await client.cache.databaseUpdatesPublisher()
            .filter { @Sendable [weak collection] in
                collection?.isRelevantUpdate(hook: $0) == true
            }
            .collect(.byTime(DispatchQueue.main, .milliseconds(50)))
            .values
        for await _ in batches {
            await reload()
        }
    }

    // MARK: Read helper

    /// Reads the current snapshot from the collection into `items` and
    /// recomputes the derived `displayItems`. SQLite-read errors are logged only.
    private func reload() async {
        do {
            let metadataItems = try await collection.loadItems()
            guard !Task.isCancelled else { return }
            // Rebuild the resolved-media side store from this batch so
            // `makeDetailVM(for:)` can hand the detail screen a fully-
            // hydrated payload without re-fetching.
            var resolved: [Int64: MediaWithEditContext] = [:]
            for item in metadataItems {
                if let media = item.resolvedMedia { resolved[item.id] = media }
            }
            self.resolvedMediaByID = resolved
            withAnimation {
                items = metadataItems.map(MediaGridItem.init(item:))
                displayItems = Self.applyingKindFilter(items, kind: kind)
            }
            reconcileSelection()
        } catch {
            if !(error is CancellationError) {
                Loggers.mediaLibrary.error("Failed to load items: \(error)")
            }
        }
    }

    /// Drops any selected id (and its share snapshot) that the loaded item set
    /// no longer contains, so the toolbar count can't strand a ghost the user
    /// can't deselect and bulk share can't 404 on a deleted item's stale URL.
    /// Guarded on `isLoadComplete`: during initial load / pagination `items`
    /// holds only a partial set, and pruning there would drop a legitimate
    /// selection on a not-yet-loaded page (the share snapshot deliberately
    /// survives pagination). Once every page is loaded, an absent id is a real
    /// deletion.
    private func reconcileSelection() {
        guard isLoadComplete, !selectedIDs.isEmpty else { return }
        let liveIDs = Set(items.map(\.id))
        let staleIDs = selectedIDs.filter { !liveIDs.contains($0) }
        guard !staleIDs.isEmpty else { return }
        for id in staleIDs {
            selectedIDs.remove(id)
            selectedMediaSnapshots[id] = nil
        }
    }

    // MARK: Detail navigation

    /// Test-only: replace the private `resolvedMediaByID` map and rebuild
    /// `items`. Simulates the cache mutation that production `reload()`
    /// would otherwise perform. The `test`-prefixed name flags intent;
    /// production code does not call this. Declared unconditional for the
    /// same reason as `testOverrideHasClient`.
    func testReplaceResolvedMedia(_ resolved: [Int64: MediaWithEditContext]) {
        self.resolvedMediaByID = resolved
        self.items = resolved.map { id, media in
            MediaGridItem(media: media, id: id, state: .loaded(isUpToDate: true))
        }
    }

    /// Cheap check for whether the cell should render as tappable. Mirrors
    /// the early-out conditions in `makeDetailVM(for:)` without
    /// constructing the throwaway detail VM on every cell render. Tests
    /// can set `testOverrideHasClient = true` to flip the client gate
    /// open; the resolved-payload check applies regardless.
    func canOpenDetail(for item: MediaGridItem) -> Bool {
        detailNavigator != nil && resolvedMediaByID[item.id] != nil
    }

    /// Whether Select should be enabled. Evaluated over `displayItems` (the
    /// kind-filtered grid the user actually sees), not the unfiltered `items`,
    /// so Select can't enter selection mode over an empty filtered grid. The
    /// `contains` short-circuits on the first openable item.
    var canEnterSelectionMode: Bool {
        displayItems.contains { canOpenDetail(for: $0) }
    }

    /// Builds a `MediaDetailViewModel` for the tapped cell. Returns nil when
    /// the cell carries no resolvable payload (placeholder states), or when the
    /// instance has no detail wiring (e.g. a search-results grid).
    func makeDetailVM(for item: MediaGridItem) -> MediaDetailViewModel? {
        guard let urlOpener,
            let shareService,
            let detailNavigator,
            let detailCapabilities,
            let media = resolvedMediaByID[item.id]
        else { return nil }
        return MediaDetailViewModel(
            media: media,
            client: client,
            tracker: tracker,
            urlOpener: urlOpener,
            shareService: shareService,
            navigator: detailNavigator,
            capabilities: detailCapabilities
        )
    }
}

extension MediaLibraryViewModel: ExternalMediaPickerDelegate {
    func didPick(remoteMedia: [ExternalRemoteMedia]) {
        let sources = remoteMedia.map { media in
            UploadSource.remoteURL(
                UploadSource.RemoteURL(
                    url: media.url,
                    suggestedName: media.suggestedName,
                    contentType: media.contentType,
                    caption: media.caption
                )
            )
        }
        Task { await self.enqueue(sources: sources) }
    }

    func didPick(imagePlaygroundFile url: URL, suggestedName: String) {
        Task {
            await self.enqueue(sources: [.imagePlayground(url, suggestedName: suggestedName)])
        }
    }

    func didCancel() {
        // No-op today; hook exists for future analytics if needed.
    }
}
