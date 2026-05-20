import Testing
import WordPressAPI
import WordPressAPIInternal
@testable import WordPressMediaLibrary

@Suite("MediaLibraryViewModel bulk-share analytics exceptions")
@MainActor
struct MediaLibraryViewModelBulkShareAnalyticsTests {

    @Test func allValidSelection_tracksFullCount() {
        let tracker = RecordingMediaTracker()
        let m1 = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let m2 = makeMediaFixture(id: 2, sourceUrl: "https://example.com/b.jpg")
        let vm = makeSelectionVM(tracker: tracker, resolvedMedia: [1: m1, 2: m2])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: m1, id: 1, state: .loaded(isUpToDate: true)))
        vm.toggleSelection(for: MediaGridItem(media: m2, id: 2, state: .loaded(isUpToDate: true)))

        vm.startBulkShare()

        let shareEvents = tracker.events.compactMap { event -> Int? in
            if case .siteMediaShareTapped(let count) = event { return count } else { return nil }
        }
        #expect(shareEvents == [2])
        #expect(vm.bulkShareRequest?.items.count == 2)
    }

    @Test func partialPrepare_tracksPreparedCount() {
        let tracker = RecordingMediaTracker()
        let valid = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let bogus = makeMediaFixture(id: 2, sourceUrl: "")
        let vm = makeSelectionVM(tracker: tracker, resolvedMedia: [1: valid, 2: bogus])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: valid, id: 1, state: .loaded(isUpToDate: true)))
        vm.toggleSelection(for: MediaGridItem(media: bogus, id: 2, state: .loaded(isUpToDate: true)))

        vm.startBulkShare()

        let shareEvents = tracker.events.compactMap { event -> Int? in
            if case .siteMediaShareTapped(let count) = event { return count } else { return nil }
        }
        #expect(shareEvents == [1])
        #expect(vm.bulkShareRequest?.items.count == 1)
    }

    @Test func allDropped_firesNoEvent() {
        let tracker = RecordingMediaTracker()
        let ftp1 = makeMediaFixture(id: 1, sourceUrl: "ftp://example.com/a.jpg")
        let ftp2 = makeMediaFixture(id: 2, sourceUrl: "ftp://example.com/b.jpg")
        let vm = makeSelectionVM(tracker: tracker, resolvedMedia: [1: ftp1, 2: ftp2])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: ftp1, id: 1, state: .loaded(isUpToDate: true)))
        vm.toggleSelection(for: MediaGridItem(media: ftp2, id: 2, state: .loaded(isUpToDate: true)))

        vm.startBulkShare()

        let shareEvents = tracker.events.compactMap { event -> Int? in
            if case .siteMediaShareTapped(let count) = event { return count } else { return nil }
        }
        #expect(shareEvents == [])
        #expect(vm.bulkShareRequest == nil)
        #expect(vm.bulkShareState == .idle)
    }
}
