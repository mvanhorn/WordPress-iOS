import DesignSystem
import SwiftUI
import UIKit
import WordPressAPI
import WordPressAPIInternal
import WordPressCore

/// Container for the Media Library screen. Holds the library view model (kept
/// alive across search so clearing the field restores the library without a
/// refetch), owns the kind filter toolbar, the aspect-ratio toggle, and the
/// search field, and switches between the library grid and the search results.
struct MediaLibraryView: View {
    @ObservedObject var viewModel: MediaLibraryViewModel
    let service: WpService
    let client: WordPressClient
    let tracker: any MediaTracker
    var externalPickerOptions: [ExternalMediaPickerOption] = []
    /// When the host app shows a bottom tab bar (e.g. Jetpack), the search
    /// field minimizes into a toolbar button so it doesn't stack a second bar
    /// at the bottom of the screen. Without a tab bar (e.g. WordPress, iPad
    /// split view) it stays a full-width search bar.
    var prefersMinimizedSearchBar = false

    @State private var searchText = ""
    @State private var isAspectRatioMode = AspectRatioPreference.load()
    /// Incremented by the Retry button so its `.task(id:)` re-fires; the initial
    /// value 0 is ignored so we don't double-load on appearance.
    @State private var retryToken = 0
    @State private var activePicker: ActivePicker?
    @State private var isPresentingUploads = false
    @State private var isPresentingDeleteConfirm = false

    private enum ActivePicker: Hashable, Identifiable {
        case photoLibrary, takePhoto, takeVideo, chooseFile
        case external(id: String)
        var id: Self { self }
    }

    private var deleteConfirmMessage: String {
        let count = viewModel.selectedIDs.count
        return count == 1 ? Strings.detailDeleteConfirmation : Strings.selectionDeleteConfirmationMany
    }

    /// `.alert(isPresented:)` needs a Bool binding; these bridge the optional
    /// error messages to one and clear the message when the alert dismisses.
    private var bulkDeleteErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.bulkDeleteErrorMessage != nil },
            set: { if !$0 { viewModel.bulkDeleteErrorMessage = nil } }
        )
    }
    private var bulkShareErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.bulkShareErrorMessage != nil },
            set: { if !$0 { viewModel.bulkShareErrorMessage = nil } }
        )
    }

    var body: some View {
        ZStack {
            if searchText.isEmpty {
                VStack(spacing: 0) {
                    if let summary = viewModel.bannerSummary {
                        BannerView(
                            summary: summary,
                            onTap: viewModel.isSelectionModeActive
                                ? nil
                                : {
                                    isPresentingUploads = true
                                }
                        )
                    }
                    MediaGridView(items: viewModel.displayItems, isAspectRatioMode: isAspectRatioMode) { item in
                        cellContent(for: item)
                    }
                    .refreshable { await viewModel.refresh() }
                    .overlay { libraryOverlay }
                }
            } else {
                MediaLibrarySearchView(
                    service: service,
                    client: client,
                    tracker: tracker,
                    searchText: $searchText,
                    isAspectRatioMode: isAspectRatioMode
                )
            }
        }
        // The library load/observe tasks live on the always-present container,
        // not inside the `searchText.isEmpty` branch, so toggling search does
        // not tear them down and re-fire a full reload.
        .task { tracker.track(.mediaLibraryOpened) }
        .task { await viewModel.load() }
        .task { await viewModel.observe() }
        .task(id: retryToken) {
            guard retryToken > 0 else { return }
            await viewModel.refresh()
        }
        .navigationTitle(Strings.title)
        // Search is suppressed entirely in selection mode: leaving it live let
        // the user swap to the search results view while the selection toolbar
        // (and its trash/share actions) kept operating on now-off-screen items,
        // and on iOS 26 the minimized search capsule also collided with the
        // bottom selection bar. Clearing searchText on entry guarantees the
        // library grid (not stale search results) is what's selected against.
        .modifier(
            SelectionAwareSearch(
                isSuppressed: viewModel.isSelectionModeActive,
                text: $searchText,
                prompt: Strings.searchPrompt,
                minimized: prefersMinimizedSearchBar
            )
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onChange(of: viewModel.isSelectionModeActive) { _, isActive in
            if isActive { searchText = "" }
        }
        .toolbar {
            if viewModel.isSelectionModeActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Strings.commonDone) { viewModel.exitSelectionMode() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if viewModel.detailCapabilities?.supportsDeletion == true {
                        Button {
                            isPresentingDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(Strings.selectionDeleteAccessibilityLabel)
                        .disabled(viewModel.selectedIDs.isEmpty || viewModel.isPreparingBulkShare)
                    } else {
                        Image(systemName: "trash")
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    Spacer()
                    Text(viewModel.selectionToolbarTitle).font(.headline)
                    Spacer()
                    shareToolbarButton
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Strings.selectionSelect) { viewModel.enterSelectionMode() }
                        // Enablement tracks the visible (kind-filtered) grid, not
                        // the unfiltered item set, so Select can't enter a Done-only
                        // dead end over an empty filtered grid.
                        .disabled(!viewModel.canEnterSelectionMode)
                }
                filterMenu
                addMenu
            }
        }
        .navigationBarBackButtonHidden(viewModel.isSelectionModeActive)
        .confirmationDialog(
            deleteConfirmMessage,
            isPresented: $isPresentingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(Strings.detailDeleteAction, role: .destructive) {
                Task { await viewModel.confirmBulkDelete() }
            }
            Button(Strings.commonCancel, role: .cancel) {}
        }
        .alert(
            Strings.detailUnableToDeleteTitle,
            isPresented: bulkDeleteErrorBinding,
            presenting: viewModel.bulkDeleteErrorMessage
        ) { _ in
            Button(Strings.commonOK, role: .cancel) { viewModel.bulkDeleteErrorMessage = nil }
        } message: {
            Text($0)
        }
        .alert(
            Strings.detailUnableToShareTitle,
            isPresented: bulkShareErrorBinding,
            presenting: viewModel.bulkShareErrorMessage
        ) { _ in
            Button(Strings.commonOK, role: .cancel) { viewModel.bulkShareErrorMessage = nil }
        } message: {
            Text($0)
        }
        // Present the Uploads queue as a sheet rather than a push. It's a
        // self-contained management surface (its own toolbar + bulk menu), and
        // modal presentation keeps it reachable from any point in the detail
        // navigation stack without the cell-tap push and the Uploads push
        // fighting over the same back stack.
        .sheet(isPresented: $isPresentingUploads) {
            NavigationStack {
                UploadsView(viewModel: viewModel)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if #available(iOS 26, *) {
                                Button(role: .close) {
                                    isPresentingUploads = false
                                }
                            } else {
                                Button {
                                    isPresentingUploads = false
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .accessibilityLabel(Strings.uploadsScreenClose)
                            }
                        }
                    }
            }
        }
        .sheet(item: $viewModel.sharePayload) { payload in
            ShareSheetRepresentable(urls: payload.urls) { completed in
                // Clean up via the captured `payload`, not viewModel.sharePayload:
                // an interactive swipe-dismiss can nil the published binding
                // before this handler runs, which would otherwise skip cleanup
                // and leak the media-share-<UUID> temp dir.
                payload.cleanupTemporaryFiles()
                viewModel.reportShareDismissed(completed: completed)
            }
        }
        .task(id: viewModel.bulkShareRequest?.id) { [request = viewModel.bulkShareRequest] in
            guard let request else { return }
            await viewModel.performBulkShare(request)
        }
        .sheet(item: $activePicker) { picker in
            switch picker {
            case .photoLibrary:
                PhotosPickerRepresentable(
                    onPicked: { sources in
                        activePicker = nil
                        Task { await viewModel.enqueue(sources: sources) }
                    },
                    onCancel: { activePicker = nil }
                )
                .ignoresSafeArea()
            case .takePhoto:
                CameraPickerRepresentable(
                    mode: .photo,
                    onPicked: { source in
                        activePicker = nil
                        Task { await viewModel.enqueue(sources: [source]) }
                    },
                    onCancel: { activePicker = nil }
                )
                .ignoresSafeArea()
            case .takeVideo:
                CameraPickerRepresentable(
                    mode: .video,
                    onPicked: { source in
                        activePicker = nil
                        Task { await viewModel.enqueue(sources: [source]) }
                    },
                    onCancel: { activePicker = nil }
                )
                .ignoresSafeArea()
            case .chooseFile:
                EmptyView()
                    .fileImporter(
                        isPresented: .constant(true),
                        allowedContentTypes: viewModel.uploader?.filePickerContentTypes ?? [],
                        allowsMultipleSelection: true,
                        onCompletion: { result in
                            activePicker = nil
                            if case .success(let urls) = result {
                                let sources = urls.map { UploadSource.file($0) }
                                Task { await viewModel.enqueue(sources: sources) }
                            }
                        }
                    )
            case .external(let id):
                if let option = externalPickerOptions.first(where: { $0.id == id }) {
                    option.sheetContent(viewModel)
                }
            }
        }
    }

    /// Wraps openable grid cells in the interaction that matches the current mode.
    /// Placeholder cells (.fetching / .missing / .failed) stay static so taps
    /// don't push or select a half-baked detail screen.
    @ViewBuilder private func cellContent(for item: MediaGridItem) -> some View {
        let isPendingDelete = viewModel.pendingDeleteIDs.contains(item.id)

        if isPendingDelete {
            MediaGridCell(item: item, isAspectRatioMode: isAspectRatioMode)
                .overlay { ProgressView().tint(.white).shadow(radius: 2) }
                .opacity(0.4)
                .allowsHitTesting(false)
                .accessibilityValue(Strings.cellDeletingAccessibilityValue)
                .disabled(true)
        } else if viewModel.isSelectionModeActive {
            if viewModel.canOpenDetail(for: item) {
                let isSelected = viewModel.isSelected(item)
                Button {
                    viewModel.toggleSelection(for: item)
                } label: {
                    MediaGridCell(item: item, isAspectRatioMode: isAspectRatioMode)
                        .overlay(alignment: .topTrailing) {
                            selectionBadge(isSelected: isSelected)
                                .opacity(viewModel.isPreparingBulkShare ? 0.5 : 1.0)
                        }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isPreparingBulkShare)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityValue(isSelected ? Strings.accessibilitySelected : Strings.accessibilityNotSelected)
            } else {
                MediaGridCell(item: item, isAspectRatioMode: isAspectRatioMode)
                    .opacity(0.4)
            }
        } else {
            if viewModel.canOpenDetail(for: item) {
                Button {
                    pushDetail(for: item)
                } label: {
                    MediaGridCell(item: item, isAspectRatioMode: isAspectRatioMode)
                }
                .buttonStyle(.plain)
            } else {
                MediaGridCell(item: item, isAspectRatioMode: isAspectRatioMode)
            }
        }
    }

    private func pushDetail(for item: MediaGridItem) {
        // Re-resolve the detail VM at push time so we don't capture a stale
        // snapshot if the underlying cache row was refreshed between the
        // cell rendering and the user's tap.
        guard let detailVM = viewModel.makeDetailVM(for: item) else { return }
        let host = UIHostingController(rootView: MediaDetailView(viewModel: detailVM))
        host.navigationItem.largeTitleDisplayMode = .never
        viewModel.detailNavigator?.push(host)
    }

    @ToolbarContentBuilder private var filterMenu: some ToolbarContent {
        if searchText.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        filterButton(for: nil)
                        ForEach(MediaKind.allCases, id: \.self) { kind in
                            filterButton(for: kind)
                        }
                    }
                    Section {
                        Button {
                            isAspectRatioMode.toggle()
                            AspectRatioPreference.save(isAspectRatioMode)
                            tracker.track(.mediaLibraryGridModeToggled(isAspectRatio: isAspectRatioMode))
                        } label: {
                            Label(
                                isAspectRatioMode ? Strings.squareGrid : Strings.aspectRatioGrid,
                                systemImage: isAspectRatioMode
                                    ? "rectangle.arrowtriangle.2.outward"
                                    : "rectangle.arrowtriangle.2.inward"
                            )
                        }
                    }
                } label: {
                    // Switch to the filled variant in the app accent color while
                    // a kind filter is active so the toolbar shows the library is
                    // filtered (the default toolbar tint renders black here).
                    if viewModel.kind == nil {
                        Image(systemName: "line.3.horizontal.decrease")
                    } else {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder private var addMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(Strings.addMenuPhotoLibrary, systemImage: "photo.on.rectangle") {
                    activePicker = .photoLibrary
                }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button(Strings.addMenuTakePhoto, systemImage: "camera") {
                        activePicker = .takePhoto
                    }
                    Button(Strings.addMenuTakeVideo, systemImage: "video") {
                        activePicker = .takeVideo
                    }
                }
                Button(Strings.addMenuChooseFile, systemImage: "folder") {
                    activePicker = .chooseFile
                }
                if !externalPickerOptions.isEmpty {
                    Section {
                        ForEach(externalPickerOptions) { option in
                            Button(option.label, systemImage: option.systemImage) {
                                activePicker = .external(id: option.id)
                            }
                        }
                        // TODO: AINFRA-1496 — when the server-side numeric size field
                        // lands, add a "View Usage" item here that opens
                        // MediaStorageDetailsView (V1 view, kept alive in the app target).
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel(Strings.addMenuTitle)
            }
        }
    }

    @ViewBuilder private func filterButton(for kind: MediaKind?) -> some View {
        let title = kind?.title ?? Strings.filterAll
        let isSelected = kind == viewModel.kind
        Button {
            viewModel.setKind(kind)
        } label: {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else if let systemImage = kind?.systemImageName {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
    }

    @ViewBuilder private var libraryOverlay: some View {
        if viewModel.shouldDisplayInitialLoading {
            ProgressView()
        } else if let error = viewModel.errorToDisplay() {
            errorView(error)
        } else if viewModel.shouldDisplayFilterEmpty {
            ContentUnavailableView(Strings.emptyFiltered, systemImage: "photo.on.rectangle")
        } else if viewModel.shouldDisplayEmpty {
            ContentUnavailableView(Strings.empty, systemImage: "photo.on.rectangle")
        }
    }

    @ViewBuilder private var shareToolbarButton: some View {
        if viewModel.isPreparingBulkShare {
            ProgressView()
                .accessibilityLabel(Strings.shareAccessibilityPreparing)
        } else {
            Button {
                viewModel.startBulkShare()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(Strings.commonShare)
            .disabled(viewModel.selectedIDs.isEmpty)
        }
    }

    @ViewBuilder private func selectionBadge(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 24, height: 24)
            Circle()
                .stroke(Color.white.opacity(isSelected ? 1.0 : 0.85), lineWidth: 2)
                .frame(width: 24, height: 24)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
        }
        .padding(6)
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(error.localizedDescription)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(Strings.errorRetry) {
                retryToken += 1
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

/// Applies `.searchable` (and the iOS 26 minimize behavior) only when search is
/// not suppressed. Selection mode suppresses it so the search field can't stay
/// live underneath the selection toolbar; when `isSuppressed` flips, SwiftUI
/// adds/removes the search field wholesale.
private struct SelectionAwareSearch: ViewModifier {
    let isSuppressed: Bool
    @Binding var text: String
    let prompt: String
    let minimized: Bool

    func body(content: Content) -> some View {
        if isSuppressed {
            content
        } else {
            content
                .searchable(text: $text, prompt: prompt)
                .minimizedSearchToolbarBehavior(minimized)
        }
    }
}

private extension View {
    /// Collapses the `.searchable` field into a toolbar button that expands on
    /// tap. Only applied when `isMinimized` is true (host app has a bottom tab
    /// bar); otherwise the search field stays a full-width bar. The `.minimize`
    /// behavior is iOS 26+, so this is a no-op on earlier versions.
    @ViewBuilder
    func minimizedSearchToolbarBehavior(_ isMinimized: Bool) -> some View {
        if #available(iOS 26, *), isMinimized {
            searchToolbarBehavior(.minimize)
        } else {
            self
        }
    }
}
