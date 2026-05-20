import Foundation
import Testing
import WordPressAPI
import WordPressAPIInternal
@testable import WordPressMediaLibrary

@Suite("MediaLibraryViewModel bulk share")
@MainActor
struct MediaLibraryViewModelBulkShareTests {

    private func makeSharePayloadFile() throws -> (fileURL: URL, directoryURL: URL) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("shared-file.jpg")
        try Data("dummy".utf8).write(to: fileURL)
        return (fileURL, directoryURL)
    }

    // MARK: - startBulkShare guards

    @Test func startBulkShare_emptySelection_isNoOp() {
        let vm = makeSelectionVM()
        vm.startBulkShare()
        #expect(vm.bulkShareState == .idle)
        #expect(vm.bulkShareRequest == nil)
    }

    @Test func startBulkShare_alreadyPreparing_isNoOp() {
        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        let originalRequestID = vm.bulkShareRequest?.id
        #expect(originalRequestID != nil)
        #expect(vm.bulkShareState == .preparing)
        vm.startBulkShare()
        #expect(vm.bulkShareRequest?.id == originalRequestID)
    }

    // MARK: - performBulkShare paths

    @Test func performBulkShare_success_setsSharePayload() async {
        let url = URL(string: "file:///tmp/a.jpg")!
        let svc = FakeShareService()
        svc.outcome = .success(urls: [url], cleanup: nil)
        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(shareService: svc, resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        let request = vm.bulkShareRequest!
        await vm.performBulkShare(request)
        #expect(vm.sharePayload?.urls == [url])
        #expect(vm.bulkShareState == .idle)
        #expect(vm.bulkShareRequest == nil)
    }

    @Test func performBulkShare_throwsCancellation_silent() async {
        let svc = FakeShareService()
        svc.outcome = .throwing(CancellationError())
        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(shareService: svc, resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        await vm.performBulkShare(vm.bulkShareRequest!)
        #expect(vm.sharePayload == nil)
        #expect(vm.bulkShareState == .idle)
        #expect(vm.bulkShareRequest == nil)
    }

    @Test func performBulkShare_throwsURLCancelled_silent() async {
        let svc = FakeShareService()
        svc.outcome = .throwing(URLError(.cancelled))
        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(shareService: svc, resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        await vm.performBulkShare(vm.bulkShareRequest!)
        #expect(vm.sharePayload == nil)
        #expect(vm.bulkShareState == .idle)
        #expect(vm.bulkShareRequest == nil)
    }

    @Test func performBulkShare_genericFailure_resetsStateAndPreservesSelection() async {
        let svc = FakeShareService()
        svc.outcome = .throwing(URLError(.notConnectedToInternet))
        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(shareService: svc, resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        await vm.performBulkShare(vm.bulkShareRequest!)
        #expect(vm.sharePayload == nil)
        #expect(vm.bulkShareState == .idle)
        #expect(vm.bulkShareRequest == nil)
        #expect(vm.isSelectionModeActive)
        #expect(Array(vm.selectedIDs) == [1])

        // Retry builds the original items, observable through bulkShareRequest.
        svc.outcome = .success(urls: [URL(string: "file:///tmp/a.jpg")!], cleanup: nil)
        vm.startBulkShare()
        #expect(vm.bulkShareRequest?.items.count == 1)
    }

    // MARK: - exitSelectionMode race

    @Test func exitSelectionMode_clearsBulkShareState_preTaskRace() {
        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        #expect(vm.bulkShareState == .preparing)
        #expect(vm.bulkShareRequest != nil)

        vm.exitSelectionMode()
        #expect(vm.bulkShareState == .idle)
        #expect(vm.bulkShareRequest == nil)

        // startBulkShare can be re-entered cleanly after exit.
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        #expect(vm.bulkShareState == .preparing)
    }

    // MARK: - Cancel/retry stale-task race

    @Test func performBulkShare_staleTaskSuccess_doesNotClobberNewerRequest() async throws {
        let (url, directoryURL) = try makeSharePayloadFile()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let svc = FakeShareService()
        svc.outcome = .success(
            urls: [url],
            cleanup: { try? FileManager.default.removeItem(at: directoryURL) }
        )

        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(shareService: svc, resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))

        vm.startBulkShare()
        let requestA = vm.bulkShareRequest!
        vm.exitSelectionMode()
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        let requestB = vm.bulkShareRequest!
        #expect(requestA.id != requestB.id)

        // Drive A's task to a successful completion AFTER B is already in flight.
        await vm.performBulkShare(requestA)

        // B's state must be intact. A's `sharePayload` write must be suppressed
        // by the `bulkShareRequest?.id == request.id` guard in performBulkShare.
        #expect(vm.bulkShareRequest?.id == requestB.id)
        #expect(vm.bulkShareState == .preparing)
        #expect(vm.sharePayload == nil)
        #expect(!FileManager.default.fileExists(atPath: directoryURL.path))
    }

    @Test func performBulkShare_staleTaskFailure_doesNotClobberNewerRequest() async {
        // Same shape as the success variant, but A's task throws a generic
        // (non-cancellation) error. The defer cleanup must still be
        // request-id-scoped: B's state must NOT be reset by A's failure.
        // The bulk share flow requires both variants to be locked down.
        let svc = FakeShareService()
        svc.outcome = .throwing(URLError(.notConnectedToInternet))

        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(shareService: svc, resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))

        vm.startBulkShare()
        let requestA = vm.bulkShareRequest!
        vm.exitSelectionMode()
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        let requestB = vm.bulkShareRequest!
        #expect(requestA.id != requestB.id)

        // Drive A's task to a generic failure AFTER B is already in flight.
        await vm.performBulkShare(requestA)

        // B's state is intact: still preparing, still holding request B.
        #expect(vm.bulkShareRequest?.id == requestB.id)
        #expect(vm.bulkShareState == .preparing)
        #expect(vm.sharePayload == nil)
    }

    // MARK: - Prepared-but-not-presented race

    @Test func exitSelectionMode_nilsAlreadyPreparedPayload() async throws {
        let (url, directoryURL) = try makeSharePayloadFile()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let svc = FakeShareService()
        svc.outcome = .success(
            urls: [url],
            cleanup: { try? FileManager.default.removeItem(at: directoryURL) }
        )

        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(shareService: svc, resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        await vm.performBulkShare(vm.bulkShareRequest!)
        #expect(vm.sharePayload?.urls == [url])
        #expect(FileManager.default.fileExists(atPath: directoryURL.path))

        vm.exitSelectionMode()
        #expect(vm.sharePayload == nil)
        #expect(!FileManager.default.fileExists(atPath: directoryURL.path))
    }

    // MARK: - reportShareDismissed (V1 bulk parity)

    @Test func reportShareDismissed_completed_exitsSelectionAndFiresNoEvent() async throws {
        let (url, directoryURL) = try makeSharePayloadFile()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let svc = FakeShareService()
        svc.outcome = .success(
            urls: [url],
            cleanup: { try? FileManager.default.removeItem(at: directoryURL) }
        )
        let tracker = RecordingMediaTracker()
        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(tracker: tracker, shareService: svc, resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        await vm.performBulkShare(vm.bulkShareRequest!)
        tracker.events.removeAll()
        vm.reportShareDismissed(completed: true)
        #expect(vm.sharePayload == nil)
        #expect(!vm.isSelectionModeActive)
        #expect(tracker.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directoryURL.path))
    }

    @Test func reportShareDismissed_cancelled_keepsSelectionAndFiresNoEvent() async throws {
        let (url, directoryURL) = try makeSharePayloadFile()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let svc = FakeShareService()
        svc.outcome = .success(
            urls: [url],
            cleanup: { try? FileManager.default.removeItem(at: directoryURL) }
        )
        let tracker = RecordingMediaTracker()
        let media = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let vm = makeSelectionVM(tracker: tracker, shareService: svc, resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true)))
        vm.startBulkShare()
        await vm.performBulkShare(vm.bulkShareRequest!)
        tracker.events.removeAll()
        vm.reportShareDismissed(completed: false)
        #expect(vm.sharePayload == nil)
        #expect(vm.isSelectionModeActive)
        #expect(Array(vm.selectedIDs) == [1])
        #expect(tracker.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directoryURL.path))
    }
}
