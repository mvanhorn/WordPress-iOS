import Testing
import WordPressAPI
import WordPressAPIInternal
@testable import WordPressMediaLibrary

@Suite("MediaLibraryViewModel snapshot survival")
@MainActor
struct MediaLibraryViewModelSnapshotSurvivalTests {
    @Test func selectionSurvivesResolvedCacheMutation() {
        let mediaA = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let mediaB = makeMediaFixture(id: 2, sourceUrl: "https://example.com/b.jpg")
        let vm = makeSelectionVM(resolvedMedia: [1: mediaA, 2: mediaB])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()

        let a = MediaGridItem(media: mediaA, id: 1, state: .loaded(isUpToDate: true))
        let b = MediaGridItem(media: mediaB, id: 2, state: .loaded(isUpToDate: true))
        vm.toggleSelection(for: a)
        vm.toggleSelection(for: b)

        vm.testReplaceResolvedMedia([:])

        #expect(Array(vm.selectedIDs) == [1, 2])
        vm.startBulkShare()
        #expect(vm.bulkShareRequest?.items.count == 2)
    }

    @Test func snapshotSurvivesPartialResolvedCacheReplacement() {
        let mediaA = makeMediaFixture(id: 1, sourceUrl: "https://example.com/a.jpg")
        let mediaB = makeMediaFixture(id: 2, sourceUrl: "https://example.com/b.jpg")
        let vm = makeSelectionVM(resolvedMedia: [1: mediaA, 2: mediaB])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()

        vm.toggleSelection(for: MediaGridItem(media: mediaA, id: 1, state: .loaded(isUpToDate: true)))
        vm.toggleSelection(for: MediaGridItem(media: mediaB, id: 2, state: .loaded(isUpToDate: true)))

        vm.testReplaceResolvedMedia([1: mediaA])

        #expect(Array(vm.selectedIDs) == [1, 2])
        vm.startBulkShare()
        #expect(vm.bulkShareRequest?.items.count == 2)
    }
}
