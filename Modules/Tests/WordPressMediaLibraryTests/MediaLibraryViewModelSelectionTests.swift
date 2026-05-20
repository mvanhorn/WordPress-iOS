import Testing
import WordPressAPI
import WordPressAPIInternal
@testable import WordPressMediaLibrary

@Suite("MediaLibraryViewModel selection state")
@MainActor
struct MediaLibraryViewModelSelectionTests {
    @Test func defaultState() {
        let vm = makeSelectionVM()
        #expect(!vm.isSelectionModeActive)
        #expect(vm.selectedIDs.isEmpty)
        #expect(vm.pendingDeleteIDs.isEmpty)
        #expect(vm.bulkShareState == .idle)
        #expect(vm.bulkShareRequest == nil)
        #expect(vm.sharePayload == nil)
    }

    @Test func enterSelectionMode_setsFlag() {
        let vm = makeSelectionVM()
        vm.enterSelectionMode()
        #expect(vm.isSelectionModeActive)
    }

    @Test func selectionToolbarTitle_empty() {
        let vm = makeSelectionVM()
        #expect(vm.selectionToolbarTitle == Strings.selectionTitleEmpty)
    }

    @Test func selectionToolbarTitle_oneImage() {
        let imageMedia = makeMediaFixture(id: 1, mimeType: "image/jpeg")
        let vm = makeSelectionVM(resolvedMedia: [1: imageMedia])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: imageMedia, id: 1, state: .loaded(isUpToDate: true)))
        #expect(vm.selectionToolbarTitle == String.localizedStringWithFormat(Strings.selectionTitleImageSingular, 1))
    }

    @Test func selectionToolbarTitle_twoImages() {
        let m1 = makeMediaFixture(id: 1, mimeType: "image/png")
        let m2 = makeMediaFixture(id: 2, mimeType: "image/jpeg")
        let vm = makeSelectionVM(resolvedMedia: [1: m1, 2: m2])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: m1, id: 1, state: .loaded(isUpToDate: true)))
        vm.toggleSelection(for: MediaGridItem(media: m2, id: 2, state: .loaded(isUpToDate: true)))
        #expect(vm.selectionToolbarTitle == String.localizedStringWithFormat(Strings.selectionTitleImagePlural, 2))
    }

    @Test func selectionToolbarTitle_mixedKinds_usesItemPlural() {
        let image = makeMediaFixture(id: 1, mimeType: "image/png")
        let video = makeMediaFixture(id: 2, mimeType: "video/mp4")
        let vm = makeSelectionVM(resolvedMedia: [1: image, 2: video])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: image, id: 1, state: .loaded(isUpToDate: true)))
        vm.toggleSelection(for: MediaGridItem(media: video, id: 2, state: .loaded(isUpToDate: true)))
        #expect(vm.selectionToolbarTitle == String.localizedStringWithFormat(Strings.selectionTitleItemPlural, 2))
    }

    @Test func selectionToolbarTitle_oneVideo_usesItemSingular() {
        let video = makeMediaFixture(id: 1, mimeType: "video/mp4")
        let vm = makeSelectionVM(resolvedMedia: [1: video])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        vm.toggleSelection(for: MediaGridItem(media: video, id: 1, state: .loaded(isUpToDate: true)))
        #expect(vm.selectionToolbarTitle == String.localizedStringWithFormat(Strings.selectionTitleItemSingular, 1))
    }

    @Test func exitSelectionMode_resetsAllSelectionFields() {
        let vm = makeSelectionVM()
        vm.enterSelectionMode()
        vm.exitSelectionMode()
        #expect(!vm.isSelectionModeActive)
        #expect(vm.selectedIDs.isEmpty)
    }

    @Test func toggleSelection_addsThenRemoves() {
        let media1 = makeMediaFixture(id: 1)
        let media2 = makeMediaFixture(id: 2)
        let vm = makeSelectionVM(resolvedMedia: [1: media1, 2: media2])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()

        let item1 = MediaGridItem(media: media1, id: 1, state: .loaded(isUpToDate: true))
        let item2 = MediaGridItem(media: media2, id: 2, state: .loaded(isUpToDate: true))

        vm.toggleSelection(for: item1)
        vm.toggleSelection(for: item2)
        #expect(Array(vm.selectedIDs) == [1, 2])
        #expect(vm.isSelected(item1))
        #expect(vm.isSelected(item2))

        vm.toggleSelection(for: item1)
        #expect(Array(vm.selectedIDs) == [2])
        #expect(!vm.isSelected(item1))
    }

    @Test func toggleSelection_isNoOp_whenIdAbsentFromResolvedMap() {
        // No resolved media for id 42, so canOpenDetail returns false and toggle is a no-op.
        // We build the item using the data-bearing init (which Task 2 loosens to
        // module-internal), but its id is deliberately NOT in resolvedMediaByID,
        // so `canOpenDetail` rejects it. Avoids needing the still-private
        // placeholder init.
        let detached = makeMediaFixture(id: 42, sourceUrl: "https://example.com/x.jpg")
        let vm = makeSelectionVM(resolvedMedia: [:])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()

        let item = MediaGridItem(media: detached, id: 42, state: .loaded(isUpToDate: true))
        vm.toggleSelection(for: item)
        #expect(vm.selectedIDs.isEmpty)
    }

    @Test func toggleSelection_offThenOn_movesToTailForBadgeOrder() {
        // [A, B, C] -> toggle B off -> [A, C] -> toggle B on -> [A, C, B].
        let mediaA = makeMediaFixture(id: 1)
        let mediaB = makeMediaFixture(id: 2)
        let mediaC = makeMediaFixture(id: 3)
        let vm = makeSelectionVM(resolvedMedia: [1: mediaA, 2: mediaB, 3: mediaC])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()

        let a = MediaGridItem(media: mediaA, id: 1, state: .loaded(isUpToDate: true))
        let b = MediaGridItem(media: mediaB, id: 2, state: .loaded(isUpToDate: true))
        let c = MediaGridItem(media: mediaC, id: 3, state: .loaded(isUpToDate: true))

        vm.toggleSelection(for: a)
        vm.toggleSelection(for: b)
        vm.toggleSelection(for: c)
        vm.toggleSelection(for: b)
        vm.toggleSelection(for: b)
        #expect(Array(vm.selectedIDs) == [1, 3, 2])
    }

    @Test func setFilter_realChange_exitsSelection() {
        let media = makeMediaFixture(id: 1)
        let vm = makeSelectionVM(resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        let item = MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true))
        vm.toggleSelection(for: item)
        #expect(vm.isSelectionModeActive)
        #expect(!vm.selectedIDs.isEmpty)

        vm.setFilter(vm.filter.with(kind: .video))
        #expect(!vm.isSelectionModeActive)
        #expect(vm.selectedIDs.isEmpty)
    }

    @Test func setFilter_noOp_preservesSelection() {
        // The 300ms debounced search task fires with the initial searchText
        // ("") against the initial filter (.search == ""), producing a no-op
        // setFilter call. That must NOT exit selection mode.
        let media = makeMediaFixture(id: 1)
        let vm = makeSelectionVM(resolvedMedia: [1: media])
        vm.testOverrideHasClient = true
        vm.enterSelectionMode()
        let item = MediaGridItem(media: media, id: 1, state: .loaded(isUpToDate: true))
        vm.toggleSelection(for: item)

        vm.setFilter(vm.filter)
        #expect(vm.isSelectionModeActive)
        #expect(Array(vm.selectedIDs) == [1])
    }
}
