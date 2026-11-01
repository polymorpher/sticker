import Observation
import PhotosUI
import StickerizeKit
import SwiftUI
import UIKit

/// The app's view of the shared sticker library, plus the queue of images waiting to be turned into stickers.
@MainActor
@Observable
final class LibraryModel {
    let store = StickerStore.makeDefault()
    private(set) var library = StickerLibrary()
    var stickers: [Sticker] { library.stickers }
    /// Images being edited; non-empty presents the editor.
    var editorBatch: EditorBatch?
    var isImporting = false
    var message: UserMessage?
    /// Set by the `stickerize://import` link (from the iMessage app) to open the photo picker for a folder.
    var photoPickerRequest: ImportRequest?

    @ObservationIgnored private var observer: StickerChangeObserver?
    /// Held back while the editor sheet is up: SwiftUI drops an alert presented under a sheet.
    private var messageAfterEditing: UserMessage?

    /// An import's note is waiting to be shown (after the editor closes); nothing else should present meanwhile.
    var holdsMessage: Bool { messageAfterEditing != nil }

    struct EditorBatch: Identifiable {
        let id = UUID()
        let items: [ImportedImage]
        /// The folder the import started in (nil for the top level), and its path's names.
        let destination: UUID?
        let destinationPath: [String]
    }

    struct ImportRequest: Equatable {
        let id = UUID()
        let folder: UUID?
    }

    struct UserMessage: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    init() {
        ImageImport.purgeTemporaryFiles()
        observer = store.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func reload() {
        do {
            library = try store.library()
        } catch {
            show("Couldn't Load Stickers", error)
        }
    }

    // MARK: Importing

    /// True while an import is loading or the editor is open; import controls are disabled meanwhile, so a second
    /// batch can't replace one being edited.
    var isBusy: Bool { isImporting || editorBatch != nil }

    /// Photos arrive as temporary file copies (see `ImportedFile`). Loading can take a while for iCloud originals,
    /// so the progress overlay is up from the first item, and items that fail to load are counted.
    func importPhotos(_ items: [PhotosPickerItem], into folder: UUID?) async {
        await importBatch(count: items.count, into: folder) { index, _ in
            guard let file = try await items[index].loadTransferable(type: ImportedFile.self) else {
                throw ImageLoadingError.unreadable
            }
            return ImageImport.Loaded(images: [try ImageImport.image(ownedFile: file.url, name: file.originalName)])
        }
    }

    /// Files, and every image in a ZIP archive among them (up to `ImageImport.maxImagesPerImport` in all), the
    /// archives' folders recreated inside `folder`.
    func importFiles(_ urls: [URL], into folder: UUID?) async {
        await importBatch(count: urls.count, into: folder, itemName: { urls[$0].lastPathComponent }) { index, remaining in
            try await ImageImport.images(pickedFile: urls[index], limits: remaining)
        }
    }

    /// Called when the editor sheet closes, whether the images were saved, skipped or cancelled.
    func finishEditing() {
        if let batch = editorBatch { ImageImport.discard(batch.items) }
        editorBatch = nil
        if let pending = messageAfterEditing {
            Task {
                // Let the sheet finish dismissing before presenting the alert.
                try? await Task.sleep(for: .milliseconds(600))
                message = pending
                messageAfterEditing = nil
            }
        }
    }

    func importProviders(_ providers: [NSItemProvider], into folder: UUID?) async {
        guard !isBusy else { return }
        let supported = providers.filter(\.canLoadImage)
        guard !supported.isEmpty else {
            message = UserMessage(title: String(localized: "Nothing to Import"),
                                  body: String(localized: "That isn't an image Stickerize can use."))
            return
        }
        isImporting = true
        defer { isImporting = false }
        finishImport(await ImageImport.images(from: supported), into: folder)
    }

    /// `load` gives the images for one picked item (several for a ZIP archive), within the limits given: what's left
    /// of the import's.
    private func importBatch(count: Int, into folder: UUID?, itemName: (Int) -> String? = { _ in nil },
                             load: (Int, ImageFinder.Limits) async throws -> ImageImport.Loaded) async {
        guard count > 0, !isBusy else { return }
        isImporting = true
        defer { isImporting = false }
        var loaded = ImageImport.Loaded()
        for index in 0..<count {
            let remaining = loaded.remaining
            guard remaining.maxImages > 0 else {
                loaded.reachedLimit = true
                break
            }
            if loaded.isPastByteLimit {
                loaded.leftOutAtByteLimit += 1
                continue
            }
            do {
                loaded.add(try await load(index, remaining))
            } catch {
                loaded.add(error, item: itemName(index))
            }
        }
        finishImport(loaded, into: folder)
    }

    private func finishImport(_ loaded: ImageImport.Loaded, into folder: UUID?) {
        var notes: [String] = []
        if loaded.reachedLimit {
            notes.append(String(localized: "Only the first \(ImageImport.maxImagesPerImport) images were opened. Import the rest separately."))
        }
        if loaded.leftOutAtByteLimit > 0 {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(ImageFinder.Limits().maxTotalBytes), countStyle: .memory)
            let from = loaded.firstLeftOut.map { String(localized: " from “\(ImageFinder.displayPath($0))” on") } ?? ""
            notes.append(loaded.leftOutAtByteLimit == 1
                ? String(localized: "One more file wasn't opened\(from): one import unpacks at most \(limit) of ZIP archives. Import it separately.")
                : String(localized: "\(loaded.leftOutAtByteLimit) more files weren't opened\(from): one import unpacks at most \(limit) of ZIP archives. Import them separately."))
        }
        if loaded.tooManyFiles {
            notes.append(String(localized: "Some ZIP archives weren't opened: together they hold more than \(ImageFinder.Limits().maxEntries.formatted()) files, more than one import can take. Import them separately."))
        }
        // Each reason once, with how many items it stopped: a full disk fails every item after it the same way.
        var reasons: [String] = []
        var items: [String: [String?]] = [:]
        for problem in loaded.unpackProblems {
            if items[problem.reason] == nil { reasons.append(problem.reason) }
            items[problem.reason, default: []].append(problem.item)
        }
        for reason in reasons {
            let stopped = items[reason] ?? []
            if stopped.count == 1, let item = stopped[0] {
                notes.append(String(localized: "“\(ImageFinder.displayPath(item))” couldn't be opened: \(reason)"))
            } else {
                notes.append(stopped.count == 1 ? String(localized: "One item couldn't be opened: \(reason)")
                    : String(localized: "\(stopped.count) items couldn't be opened: \(reason)"))
            }
        }
        if loaded.overLimit > 0 {
            notes.append(loaded.overLimit == 1
                ? String(localized: "One file in the ZIP archives is larger than one import opens, or nested too deep.")
                : String(localized: "\(loaded.overLimit) files in the ZIP archives are larger than one import opens, or nested too deep."))
        }
        if loaded.failures > 0 {
            // Counted per image, so a ZIP archive's damaged or password-protected files count one by one.
            notes.append(loaded.failures == 1
                ? String(localized: "One item couldn't be read. It may not be an image, may be damaged or password-protected, or couldn't be downloaded.")
                : String(localized: "\(loaded.failures) items couldn't be read. They may not be images, may be damaged or password-protected, or couldn't be downloaded."))
        }
        let title = loaded.failures > 0 || !loaded.unpackProblems.isEmpty
            ? String(localized: "Some Images Couldn't Be Opened") : String(localized: "Some Images Weren't Opened")
        let note = notes.isEmpty ? nil : UserMessage(title: title, body: notes.joined(separator: "\n\n"))
        if loaded.images.isEmpty {
            message = note
        } else {
            messageAfterEditing = note
            // The folder may have been deleted while the import loaded; then it goes to the top level.
            let path = library.path(to: folder)
            let items = loaded.images.map { image in
                var image = image
                image.folderPath = ImportFolders.relative(image.folderPath, toDestinationNamed: path.last?.name)
                return image
            }
            editorBatch = EditorBatch(items: items, destination: path.last?.id, destinationPath: path.map(\.name))
        }
    }

    // MARK: Editing the library

    func update(_ sticker: Sticker, name: String, emoji: String) {
        perform("Couldn't Save Changes") { try store.update(sticker.id, name: name, emoji: emoji) }
    }

    func delete(_ ids: Set<UUID>) {
        perform("Couldn't Delete") { try store.delete(ids) }
    }

    func moveToFront(_ sticker: Sticker) {
        perform("Couldn't Reorder") { try store.reorder([sticker.id]) }
    }

    /// Saves stickers to Photos, then says how to make them iPhone stickers, the kind friends can save.
    func saveToPhotos(_ stickers: [Sticker]) async {
        do {
            try await StickerActions.saveToPhotos(stickers, from: store)
            message = UserMessage(
                title: stickers.count == 1 ? String(localized: "Saved to Photos") : String(localized: "Saved \(stickers.count) Stickers to Photos"),
                body: String(localized: "To add one to your iPhone stickers, open it in Photos, touch and hold the subject, then tap Add Sticker. Stickers you send from your iPhone stickers can be saved by the people you send them to."))
        } catch {
            show("Couldn't Save to Photos", error)
        }
    }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String, in parent: UUID?) -> StickerFolder? {
        var folder: StickerFolder?
        perform("Couldn't Make the Folder") { folder = try store.createFolder(named: name, in: parent) }
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        perform("Couldn't Rename the Folder") { try store.renameFolder(id, to: name) }
    }

    func deleteFolder(_ id: UUID, keepingContents: Bool) {
        perform("Couldn't Delete the Folder") { try store.deleteFolder(id, keepingContents: keepingContents) }
    }

    /// `stickerize://import`, optionally with `?folder=<id>` (the folder the iMessage app is showing).
    func handle(_ url: URL) {
        guard url.scheme == "stickerize", url.host() == "import" else { return }
        let folder = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "folder" }?.value.flatMap(UUID.init(uuidString:))
        photoPickerRequest = ImportRequest(folder: folder.flatMap { library.folder($0)?.id })
    }

    // MARK: Helpers

    func show(_ title: LocalizedStringResource, _ error: Error) {
        message = UserMessage(title: String(localized: title),
                              body: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// Presents `message` again after a sheet closes: SwiftUI drops an alert set while a sheet is up, and leaves it set.
    func presentMessageAgain() {
        guard let pending = message else { return }
        message = nil
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            message = UserMessage(title: pending.title, body: pending.body)
        }
    }

    /// Runs a store change whose error the caller shows itself (a sheet, where an alert from here would be dropped).
    func attempt<T>(_ body: () throws -> T) throws -> T {
        defer { reload() }
        return try body()
    }

    private func perform(_ title: LocalizedStringResource, _ body: () throws -> Void) {
        do { try body() } catch { show(title, error) }
        // The change notification also reloads, but do it now so the UI doesn't wait for the round trip.
        reload()
    }
}
