import SwiftUI
import UIKit
import WordPressCore
import WordPressData
import WordPressMediaLibrary

/// Single source of truth for routing into the V2 Media Library. Both V1
/// entry points (BlogDetailsViewController.showMediaLibrary and
/// DashboardQuickActionsCardCell .media case) call this helper. Returns nil
/// when either the FeatureFlag is off or the site can't construct a
/// WordPressSite, so the caller's V1 fall-through is a one-liner.
@MainActor
enum MediaLibraryRouting {
    static func makeViewController(
        for blog: Blog,
        baseAnalyticsProperties: [String: Any]
    ) -> UIViewController? {
        guard FeatureFlag.mediaLibraryV2.enabled,
            let site = try? WordPressSite(blog: blog)
        else {
            return nil
        }
        let client = WordPressClientFactory.shared.instance(for: site)

        // Explicit two-step instead of `.merging(...)`. Reason:
        // `baseAnalyticsProperties` is `[String: Any]`; a `["is_v2": "1"]`
        // literal can infer as `[String: String]` and fail to type-check
        // against the merging overload. Explicit form avoids the gamble.
        var properties = baseAnalyticsProperties
        properties["is_v2"] = "1"
        let tracker = MediaTrackerAdapter(blog: blog, baseProperties: properties)

        let uploader: MediaUploader
        do {
            uploader = try MediaUploaderRegistry.shared.uploader(for: blog)
        } catch {
            Loggers.app.error("Failed to vend uploader: \(error)")
            return nil
        }

        let urlOpener = MediaDetailURLOpenerAdapter(blog: blog)
        let shareService = MediaDetailShareServiceAdapter(blog: blog)
        let navigator = MediaDetailNavigatorAdapter()
        let capabilities = MediaLibraryCapabilities(
            supportsAltEditing: blog.supports(.mediaAltEditing),
            supportsMetadataEditing: blog.supports(.mediaMetadataEditing),
            supportsDeletion: blog.supports(.mediaDeletion)
        )

        // Minimize the search field only when the host shows a bottom tab bar
        // (e.g. Jetpack's WPTabBarController), so it doesn't stack a second bar
        // below the grid. WordPress's sidebar and the iPad split view aren't
        // tab bar controllers, so they keep the full-width search bar.
        let prefersMinimizedSearchBar = RootViewCoordinator.sharedPresenter.rootViewController is UITabBarController

        let hostingController = MediaLibraryHostingController.make(
            client: client,
            tracker: tracker,
            uploader: uploader,
            urlOpener: urlOpener,
            shareService: shareService,
            navigator: navigator,
            capabilities: capabilities,
            externalPickerOptions: externalPickerOptions(for: blog),
            prefersMinimizedSearchBar: prefersMinimizedSearchBar
        )
        urlOpener.attach(host: hostingController)
        navigator.attach(host: hostingController)
        return hostingController
    }

    /// Internal helper so tests can assert the option array without UI introspection.
    /// Mirrors V1's effective gates from MediaPickerMenu+External.swift.
    static func externalPickerOptions(for blog: Blog) -> [ExternalMediaPickerOption] {
        var options: [ExternalMediaPickerOption] = []

        if MediaPickerSource.freePhotos(blog: blog).isEnabled,
            let api = blog.wordPressComRestApi
        {
            options.append(
                .init(
                    id: "stockPhotos",
                    label: Strings.stockPhotos,
                    systemImage: "photo.on.rectangle",
                    sheetContent: { delegate in
                        AnyView(StockPhotosPickerSheet(api: api, delegate: delegate))
                    }
                )
            )
        }
        if MediaPickerSource.playground.isEnabled {
            if #available(iOS 18.1, *) {
                options.append(
                    .init(
                        id: "imagePlayground",
                        label: Strings.imagePlayground,
                        systemImage: "apple.image.playground",
                        sheetContent: { delegate in
                            AnyView(ImagePlaygroundPickerSheet(delegate: delegate))
                        }
                    )
                )
            }
        }
        return options
    }
}

private enum Strings {
    static let stockPhotos = NSLocalizedString(
        "mediaLibrary.v2.addMenu.stockPhotos",
        value: "Free Photo Library",
        comment: "Add-menu item that opens the Stock Photos picker"
    )
    static let imagePlayground = NSLocalizedString(
        "mediaLibrary.v2.addMenu.imagePlayground",
        value: "Image Playground",
        comment: "Add-menu item that opens Apple's Image Playground"
    )
}
