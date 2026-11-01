import PhotosUI
import StickerizeKit
import SwiftUI
import UniformTypeIdentifiers

/// A screen in the library's navigation stack.
enum LibraryRoute: Hashable {
    case folder(UUID)
    case sticker(UUID)
}

/// The library: a navigation stack of folder screens (the top level first) and sticker pages. Importing (pickers, drop,
/// the editor) lives here, into the folder the user started it from.
struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    /// The folder a picker imports into, captured when the user opens it.
    @State private var importDestination: UUID?
    @State private var showsSetup = false
    @State private var isDropTargeted = false
    @State private var path: [LibraryRoute] = []

    /// The innermost folder on screen (nil for the top level).
    private var currentFolder: UUID? {
        path.reversed().lazy.compactMap { route -> UUID? in
            if case let .folder(id) = route { id } else { nil }
        }.first
    }

    private var actions: FolderScreen.Actions {
        FolderScreen.Actions(
            choosePhotos: { folder in
                importDestination = folder
                showsPhotoPicker = true
            },
            chooseFiles: { folder in
                importDestination = folder
                showsFileImporter = true
            },
            showSetup: { showsSetup = true },
            show: { folder in path = route(to: folder) })
    }

    var body: some View {
        @Bindable var library = library
        NavigationStack(path: $path) {
            FolderScreen(folderID: nil, actions: actions)
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    // A screen of its own per folder: replacing the path can otherwise hand one folder's screen, with
                    // its selection and search, to another.
                    case let .folder(id): FolderScreen(folderID: id, actions: actions).id(id)
                    case let .sticker(id): StickerDetailView(stickerID: id)
                    }
                }
        }
        .overlay {
            if library.isImporting {
                ProgressView("Opening…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItems, maxSelectionCount: 20,
                      matching: .images, preferredItemEncoding: .current)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            let folder = importDestination
            Task { await library.importPhotos(items, into: folder) }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: ImageImport.supportedTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                let folder = importDestination
                Task { await library.importFiles(urls, into: folder) }
            case let .failure(error): library.show("Couldn't Open the File", error)
            }
        }
        .onDrop(of: ImageImport.supportedTypes, isTargeted: $isDropTargeted) { providers in
            // A tile dragged and released inside the app would otherwise be imported again as a duplicate.
            guard !library.isBusy,
                  !providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.stickerizeSticker.identifier) })
            else { return false }
            let folder = currentFolder
            Task { await library.importProviders(providers, into: folder) }
            return true
        }
        .sheet(item: $library.editorBatch) { batch in
            StickerEditorFlow(items: batch.items, store: library.store, destination: batch.destination,
                              destinationPath: batch.destinationPath) { _ in
                library.finishEditing()
            }
        }
        .sheet(isPresented: $showsSetup, onDismiss: library.presentMessageAgain) {
            SetupGuideView()
        }
        .alert(item: $library.message) { message in
            Alert(title: Text(message.title), message: Text(message.body))
        }
        .onChange(of: library.photoPickerRequest) { openRequestedPicker() }
        .onChange(of: library.isBusy) { openRequestedPicker() }
        .onChange(of: library.message?.id) { openRequestedPicker() }
        .onChange(of: library.holdsMessage) { openRequestedPicker() }
        #if DEBUG
        .task { await runDebugLaunchActions() }
        #endif
    }

    /// Opens the photo picker a `stickerize://import` link asked for, once no import or editing is under way (photos
    /// picked meanwhile would be dropped, and the picker can't open over the editor) and no alert is up or due (it
    /// would be dropped under the picker).
    private func openRequestedPicker() {
        guard let request = library.photoPickerRequest, !library.isBusy, library.message == nil, !library.holdsMessage else { return }
        library.photoPickerRequest = nil
        path = route(to: request.folder)
        importDestination = request.folder
        // Opening the photo picker closes the Files picker without telling it, which would leave it unable to reopen.
        showsFileImporter = false
        showsPhotoPicker = true
    }

    /// The stack that shows `folder`: each folder from the top level down to it.
    private func route(to folder: UUID?) -> [LibraryRoute] {
        library.library.path(to: folder).map { .folder($0.id) }
    }

    #if DEBUG
    private func runDebugLaunchActions() async {
        if DebugLaunch.reset {
            for folder in library.library.children(of: nil) { library.deleteFolder(folder.id, keepingContents: false) }
            library.delete(Set(library.stickers.map(\.id)))
        }
        let paths = DebugLaunch.importPaths
        if !paths.isEmpty {
            await library.importFiles(paths.map { URL(fileURLWithPath: $0) }, into: nil)
            // Folders are made as stickers are saved, so wait for the editor (with auto-save) to finish.
            while library.editorBatch != nil { try? await Task.sleep(for: .milliseconds(200)) }
        }
        if DebugLaunch.copy, let first = library.stickers.first { try? StickerActions.copy(first, from: library.store) }
        switch DebugLaunch.screen {
        case "detail": if let first = library.stickers.first { path = [.sticker(first.id)] }
        case "setup": showsSetup = true
        case "folder": if let first = library.library.children(of: nil).first { path = [.folder(first.id)] }
        default: break
        }
    }
    #endif
}

/// Shown when the build has no App Group entitlement, so the extensions can't see the library.
struct StorageWarning: View {
    var body: some View {
        Label {
            Text("The shared library isn't available, so these stickers won't appear in Messages or the keyboard. The app was built without its App Group entitlement.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.footnote)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Grid thumbnail, decoded at display size off the main thread and cached.
struct StickerThumbnail: View {
    let sticker: Sticker
    let store: StickerStore
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: sticker.id) {
            image = await ThumbnailCache.shared.image(for: sticker, store: store, pixelSize: Int(160 * displayScale))
        }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for sticker: Sticker, store: StickerStore, pixelSize: Int) async -> UIImage? {
        let key = "\(sticker.id.uuidString)-\(pixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = store.fileURL(for: sticker)
        let image = await Task.detached(priority: .userInitiated) {
            ImageLoader.thumbnail(contentsOf: url, maxPixelSize: pixelSize).map { UIImage(cgImage: $0) }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
