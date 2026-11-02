import CoreTransferable
import Photos
import StickerExport
import StickerizeKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// Marks drags that start in Stickerize, so dropping a tile back on the library doesn't import a duplicate.
    /// Declared in App-Info.plist (UTExportedTypeDeclarations) as `$(BUNDLE_ID_PREFIX).sticker`, the app's bundle ID.
    static let stickerizeSticker = UTType(exportedAs: (Bundle.main.bundleIdentifier ?? "xyz.hiddenstate.stickerize") + ".sticker",
                                          conformingTo: .data)
}

/// A still sticker as a shareable PNG (share sheet, drag and drop). Uses the ≤ 512 px pasteboard copy, which other
/// apps handle best; transparency is kept.
struct StickerPNG: Transferable {
    let sticker: Sticker
    let store: StickerStore

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try item.store.pasteboardItem(for: item.sticker).data
        }
        .suggestedFileName { $0.sticker.name + ".png" }
        // An empty marker that only this process sees, so the library can refuse its own tiles as drops.
        DataRepresentation(exportedContentType: .stickerizeSticker) { _ in Data() }
            .visibility(.ownProcess)
    }
}

/// An animated sticker as its GIF.
struct StickerGIF: Transferable {
    let sticker: Sticker
    let store: StickerStore

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .gif) { item in
            try item.store.data(for: item.sticker)
        }
        .suggestedFileName { $0.sticker.name + ".gif" }
        DataRepresentation(exportedContentType: .stickerizeSticker) { _ in Data() }
            .visibility(.ownProcess)
    }
}

/// Share button for either kind of sticker.
struct StickerShareLink: View {
    let sticker: Sticker
    let store: StickerStore

    var body: some View {
        if sticker.isAnimated {
            ShareLink(item: StickerGIF(sticker: sticker, store: store), preview: SharePreview(sticker.name)) { label }
        } else {
            ShareLink(item: StickerPNG(sticker: sticker, store: store), preview: SharePreview(sticker.name)) { label }
        }
    }

    private var label: some View {
        Label("Share…", systemImage: "square.and.arrow.up")
    }
}

extension View {
    /// Drag a sticker out as PNG, or GIF when animated.
    @ViewBuilder
    func stickerDraggable(_ sticker: Sticker, store: StickerStore, @ViewBuilder preview: () -> some View) -> some View {
        if sticker.isAnimated {
            draggable(StickerGIF(sticker: sticker, store: store), preview: preview)
        } else {
            draggable(StickerPNG(sticker: sticker, store: store), preview: preview)
        }
    }
}

@MainActor
enum StickerActions {
    /// Copies the file's bytes only (PNG, or GIF when animated). A UIImage would also publish a JPEG without alpha or
    /// animation, which some apps prefer.
    static func copy(_ sticker: Sticker, from store: StickerStore) throws {
        let item = try store.pasteboardItem(for: sticker)
        UIPasteboard.general.setItems([[item.type.identifier: item.data]])
    }

    /// Saves the sticker file to Photos: the PNG with alpha, where "Add Sticker" can put it in the system sticker
    /// library, or the GIF, which Photos keeps animated.
    static func saveToPhotos(_ sticker: Sticker, from store: StickerStore) async throws {
        try await saveToPhotos([sticker], from: store)
    }

    /// Saves several stickers to Photos in one change, so either all of them are added or none.
    static func saveToPhotos(_ stickers: [Sticker], from store: StickerStore) async throws {
        let files = try stickers.map { (sticker: $0, data: try store.data(for: $0)) }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotosAccessError() }
        try await PHPhotoLibrary.shared().performChanges {
            for file in files {
                // Adding the PNG bytes as the photo resource keeps the alpha channel (a UIImage would be re-encoded).
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = file.sticker.name + "." + file.sticker.format.fileExtension
                options.uniformTypeIdentifier = file.sticker.format.type.identifier
                request.addResource(with: .photo, data: file.data, options: options)
            }
        }
    }

    struct PhotosAccessError: LocalizedError {
        var errorDescription: String? {
            String(localized: "Stickerize doesn't have permission to add to your photo library. You can allow it in Settings › Stickerize › Photos.")
        }
    }

    // MARK: Messengers

    enum Messenger: String, Identifiable, CaseIterable {
        case whatsApp, telegram

        var id: Self { self }

        var name: String {
            switch self {
            case .whatsApp: "WhatsApp"
            case .telegram: "Telegram"
            }
        }

        var allowedCount: ClosedRange<Int> {
            switch self {
            case .whatsApp: StickerPackExport.whatsAppStickerCount
            case .telegram: StickerPackExport.telegramStickerCount
            }
        }

        @MainActor
        var isInstalled: Bool {
            let scheme = self == .whatsApp ? "whatsapp://" : "tg://"
            return URL(string: scheme).map(UIApplication.shared.canOpenURL) ?? false
        }
    }

    /// Builds the pack (WebP/PNG renditions, off the main thread) and hands it to the messenger via the pasteboard.
    static func export(_ stickers: [Sticker], from store: StickerStore, to messenger: Messenger,
                       packName: String, publisher: String) async throws {
        let payload = try await Task.detached(priority: .userInitiated) {
            let items = stickers.map { sticker in
                ExportSticker(source: .file(store.fileURL(for: sticker)),
                              emojis: StickerPackExport.emojis(in: sticker.emoji ?? ""),
                              accessibilityText: sticker.name)
            }
            switch messenger {
            case .whatsApp: return try StickerPackExport.whatsApp(items, name: packName, publisher: publisher)
            case .telegram: return try StickerPackExport.telegram(items)
            }
        }.value
        try Task.checkCancellation()
        UIPasteboard.general.setItems([[payload.pasteboardType: payload.data]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(payload.expiration)])
        guard await UIApplication.shared.open(payload.openURL) else { throw MessengerMissingError(name: messenger.name) }
    }

    struct MessengerMissingError: LocalizedError {
        let name: String
        var errorDescription: String? { String(localized: "\(name) isn't installed.") }
    }
}
