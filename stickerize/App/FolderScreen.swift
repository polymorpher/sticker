import PhotosUI
import StickerizeKit
import SwiftUI

/// One level of the library: the top level (nil) or a folder. Shows its folders, then its stickers, and owns its own
/// selection, search and folder dialogs.
struct FolderScreen: View {
    /// What a screen asks of the library around it.
    struct Actions {
        /// Open the photo picker or file importer, importing into this folder.
        let choosePhotos: (UUID?) -> Void
        let chooseFiles: (UUID?) -> Void
        let showSetup: () -> Void
        /// Navigate to a folder (nil for the top level).
        let show: (UUID?) -> Void
    }

    let folderID: UUID?
    let actions: Actions

    @Environment(LibraryModel.self) private var library
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var exportTarget: StickerActions.Messenger?
    @State private var confirmsDelete = false
    @State private var searchText = ""
    @State private var moving: Moving?
    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var folderToDelete: StickerFolder?
    #if DEBUG
    /// The top level's task runs again whenever it comes back into view; the launch actions run once.
    @State private var didRunDebugActions = false
    #endif

    /// What the folder picker is moving.
    private enum Moving: Identifiable {
        case stickers(Set<UUID>)
        case folder(StickerFolder)

        var id: String {
            switch self {
            case let .stickers(ids): ids.map(\.uuidString).sorted().joined()
            case let .folder(folder): folder.id.uuidString
            }
        }
    }

    /// What the name alert is for.
    private enum Naming: Equatable {
        case newFolder
        case rename(StickerFolder)
    }

    private var folder: StickerFolder? { folderID.flatMap { library.library.folder($0) } }
    private var subfolders: [StickerFolder] { library.library.children(of: folderID) }
    private var levelStickers: [Sticker] { library.library.stickers(in: folderID) }
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Group {
            if folderID != nil, folder == nil {
                ContentUnavailableView("Folder Deleted", systemImage: "folder.badge.minus")
            } else if folderID == nil, library.library.isEmpty {
                emptyLibrary
            } else {
                content
                    .searchable(text: $searchText, prompt: folder.map { Text("Search in \($0.name)") } ?? Text("Search Stickers"))
            }
        }
        .toolbar {
            if folderID == nil || folder != nil { toolbar }
        }
        .navigationTitle(isSelecting ? selectionTitle : folder?.name ?? String(localized: "Stickers"))
        .onChange(of: searchText) { _, text in
            if !text.isEmpty { endSelection() }
        }
        .onChange(of: library.library) { _, _ in
            // Stickers deleted or moved elsewhere (by this screen or another process) leave the selection.
            selection.formIntersection(levelStickers.map(\.id))
        }
        .sheet(item: $exportTarget, onDismiss: library.presentMessageAgain) { messenger in
            ExportView(messenger: messenger, stickers: levelStickers.filter { selection.contains($0.id) },
                       suggestedPackName: folder?.name,
                       onCancel: { exportTarget = nil },
                       onExported: {
                           exportTarget = nil
                           endSelection()
                       })
        }
        .sheet(item: $moving, onDismiss: library.presentMessageAgain) { moving in
            movePicker(for: moving)
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(selection)
                endSelection()
            }
        } message: {
            Text("They'll also disappear from Messages and the keyboard.")
        }
        .confirmationDialog(folderToDelete.map { String(localized: "Delete “\($0.name)”?") } ?? "",
                            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
                            titleVisibility: .visible, presenting: folderToDelete) { folder in
            folderDeleteButtons(for: folder)
        } message: { folder in
            Text(folderDeleteMessage(for: folder))
        }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) {}
            Button(naming == .newFolder ? "Create" : "Rename") { commitName() }
        }
        #if DEBUG
        .task { runDebugLaunchActions() }
        #endif
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isSearching {
            searchResults
        } else if subfolders.isEmpty, levelStickers.isEmpty {
            emptyFolder
        } else {
            ScrollView {
                if folderID == nil, library.store.location == .local {
                    StorageWarning()
                        .padding(.horizontal)
                }
                if !subfolders.isEmpty {
                    folderGrid(subfolders)
                }
                stickerGrid(levelStickers)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let folders = library.library.searchFolders(searchText, in: folderID)
        let stickers = library.library.search(searchText, in: folderID)
        if folders.isEmpty, stickers.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ScrollView {
                if !folders.isEmpty {
                    folderGrid(folders, showsLocation: true)
                }
                stickerGrid(stickers, showsLocation: true)
            }
        }
    }

    private func folderGrid(_ folders: [StickerFolder], showsLocation: Bool = false) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 12, alignment: .top)], spacing: 16) {
            ForEach(folders) { folder in
                folderTile(for: folder, showsLocation: showsLocation)
            }
        }
        .padding([.horizontal, .top])
        .disabled(isSelecting)
        .opacity(isSelecting ? 0.4 : 1)
    }

    private func stickerGrid(_ stickers: [Sticker], showsLocation: Bool = false) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 12)], spacing: 12) {
            ForEach(stickers) { sticker in
                tile(for: sticker, showsLocation: showsLocation)
            }
        }
        .padding()
    }

    private func folderTile(for folder: StickerFolder, showsLocation: Bool) -> some View {
        let count = library.library.count(inTree: folder.id)
        let cover = library.library.cover(of: folder.id)
        let location = showsLocation ? locationText(for: folder.parentID) : nil
        let countText = count == 1 ? String(localized: "1 sticker") : String(localized: "\(count) stickers")
        return NavigationLink(value: LibraryRoute.folder(folder.id)) {
            VStack(alignment: .leading, spacing: 4) {
                Color(uiColor: .secondarySystemBackground)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let cover {
                            StickerThumbnail(sticker: cover, store: library.store).padding(16)
                        } else {
                            Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "folder.fill")
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                            .padding(6)
                            .background(.background, in: Circle())
                            .padding(6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(folder.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(location ?? countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(location.map { String(localized: "\(folder.name), folder, in \($0)") }
            ?? String(localized: "\(folder.name), folder, \(countText)")))
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                nameText = folder.name
                naming = .rename(folder)
            }
            Button("Move to…", systemImage: "folder") { moving = .folder(folder) }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { folderToDelete = folder }
        }
    }

    @ViewBuilder
    private func tile(for sticker: Sticker, showsLocation: Bool) -> some View {
        // A square cell with the sticker fitted inside, so rows line up whatever the sticker's shape.
        let thumbnail = Color(uiColor: .secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay { StickerThumbnail(sticker: sticker, store: library.store).padding(8) }
            .overlay(alignment: .topLeading) {
                if sticker.isAnimated { AnimatedBadge().padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityElement()
            .accessibilityLabel(Text(sticker.name))
        if isSelecting {
            Button {
                if selection.contains(sticker.id) { selection.remove(sticker.id) } else { selection.insert(sticker.id) }
            } label: {
                thumbnail
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: selection.contains(sticker.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(selection.contains(sticker.id) ? Color.accentColor : .secondary)
                            .background(Circle().fill(.background))
                            .padding(6)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(sticker.id) ? .isSelected : [])
        } else {
            NavigationLink(value: LibraryRoute.sticker(sticker.id)) {
                if showsLocation, let location = locationText(for: sticker.folderID) {
                    VStack(spacing: 4) {
                        thumbnail
                        Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    thumbnail
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") {
                    do { try StickerActions.copy(sticker, from: library.store) } catch { library.show("Couldn't Copy", error) }
                }
                StickerShareLink(sticker: sticker, store: library.store)
                Button("Move to…", systemImage: "folder") { moving = .stickers([sticker.id]) }
                if showsLocation, sticker.folderID != folderID {
                    Button("Show in Folder", systemImage: "folder") { actions.show(sticker.folderID) }
                }
                Button("Move to Front", systemImage: "arrow.up.to.line") { library.moveToFront(sticker) }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { library.delete([sticker.id]) }
            }
            .stickerDraggable(sticker, store: library.store) {
                StickerThumbnail(sticker: sticker, store: library.store).frame(width: 120, height: 120)
            }
        }
    }

    /// Where a search result is, below this screen's folder ("Cats › Happy"); nil when it is right here.
    private func locationText(for folder: UUID?) -> String? {
        let path = library.library.path(to: folder).dropFirst(library.library.path(to: folderID).count)
        return path.isEmpty ? nil : path.map(\.name).joined(separator: " › ")
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label {
                Text("Make Your First Sticker")
            } icon: {
                Image("StickerArt")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
            }
        } description: {
            Text("Pick a photo and Stickerize cuts out the subject. Your stickers show up in Messages, in the emoji keyboard's Stickers, and in the Stickerize keyboard.")
            if library.store.location == .local {
                StorageWarning()
            }
        } actions: {
            Group {
                // Semibold: white on the dark-mode accent is 3.4:1, which meets the bar for bold text.
                Button("Choose Photos") { actions.choosePhotos(nil) }
                    .buttonStyle(.borderedProminent)
                    .fontWeight(.semibold)
                Button("Choose Files") { actions.chooseFiles(nil) }
                PasteButton(supportedContentTypes: ImageImport.supportedTypes) { providers in
                    Task { await library.importProviders(providers, into: nil) }
                }
            }
            .disabled(library.isBusy)
            Button("How to Use Your Stickers") { actions.showSetup() }
        }
    }

    private var emptyFolder: some View {
        ContentUnavailableView {
            Label("No Stickers in This Folder", systemImage: "folder")
        } description: {
            Text("Add photos or files here, or move stickers in from another folder.")
        } actions: {
            Group {
                Button("Choose Photos") { actions.choosePhotos(folderID) }
                    .buttonStyle(.borderedProminent)
                Button("Choose Files") { actions.chooseFiles(folderID) }
            }
            .disabled(library.isBusy)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == levelStickers.count ? "Deselect All" : "Select All") {
                    selection = selection.count == levelStickers.count ? [] : Set(levelStickers.map(\.id))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: endSelection)
                    .fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    .disabled(selection.isEmpty)
                Spacer()
                Button("Move to…", systemImage: "folder") { moving = .stickers(selection) }
                    .disabled(selection.isEmpty)
                Spacer()
                Menu("Add to…", systemImage: "square.and.arrow.up.on.square") {
                    ForEach(StickerActions.Messenger.allCases) { messenger in
                        Button("Add to \(messenger.name)") { exportTarget = messenger }
                            .disabled(!messenger.allowedCount.contains(selection.count))
                    }
                    Divider()
                    Button("Save to Photos", systemImage: "photo.badge.plus") {
                        let stickers = levelStickers.filter { selection.contains($0.id) }
                        endSelection()
                        Task { await library.saveToPhotos(stickers) }
                    }
                }
                .disabled(selection.isEmpty)
            }
        } else {
            if folderID == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("How to Use", systemImage: "questionmark.circle") { actions.showSetup() }
                }
            }
            if !levelStickers.isEmpty, !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { isSelecting = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Add", systemImage: "plus") {
                    Button("Photos", systemImage: "photo.on.rectangle") { actions.choosePhotos(folderID) }
                        .disabled(library.isBusy)
                    Button("Files", systemImage: "doc") { actions.chooseFiles(folderID) }
                        .disabled(library.isBusy)
                    Divider()
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        nameText = ""
                        naming = .newFolder
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                PasteButton(supportedContentTypes: ImageImport.supportedTypes) { providers in
                    Task { await library.importProviders(providers, into: folderID) }
                }
                .labelStyle(.iconOnly)
                .disabled(library.isBusy)
            }
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? String(localized: "Select Stickers") : String(localized: "\(selection.count) Selected")
    }

    private var deleteTitle: String {
        selection.count == 1 ? String(localized: "Delete 1 sticker?") : String(localized: "Delete \(selection.count) stickers?")
    }

    private func endSelection() {
        isSelecting = false
        selection = []
    }

    // MARK: Folders

    private var namingTitle: String {
        switch naming {
        case .rename: String(localized: "Rename Folder")
        default: String(localized: "New Folder")
        }
    }

    private func commitName() {
        switch naming {
        case .newFolder: library.createFolder(named: nameText, in: folderID)
        case let .rename(folder): library.renameFolder(folder.id, to: nameText)
        case nil: break
        }
        naming = nil
    }

    private func movePicker(for moving: Moving) -> some View {
        switch moving {
        case let .stickers(ids):
            let current = Set(library.stickers.filter { ids.contains($0.id) }.map(\.folderID))
            return FolderPicker(title: ids.count == 1 ? String(localized: "Move Sticker") : String(localized: "Move \(ids.count) Stickers"),
                                current: current.count == 1 ? current.first : .none, excluded: []) { destination in
                try library.attempt { try library.store.move(ids, to: destination) }
                endSelection()
            }
        case let .folder(folder):
            return FolderPicker(title: String(localized: "Move “\(folder.name)”"), current: .some(folder.parentID),
                                excluded: library.library.subtree(of: folder.id)) { destination in
                try library.attempt { try library.store.moveFolder(folder.id, into: destination) }
            }
        }
    }

    @ViewBuilder
    private func folderDeleteButtons(for folder: StickerFolder) -> some View {
        let count = library.library.count(inTree: folder.id)
        let hasSubfolders = !library.library.children(of: folder.id).isEmpty
        if count > 0 {
            Button(count == 1 ? String(localized: "Delete Folder and 1 Sticker") : String(localized: "Delete Folder and \(count) Stickers"),
                   role: .destructive) {
                library.deleteFolder(folder.id, keepingContents: false)
            }
            Button("Delete Folder, Keep Stickers") { library.deleteFolder(folder.id, keepingContents: true) }
        } else if hasSubfolders {
            Button("Delete Folder and Its Folders", role: .destructive) { library.deleteFolder(folder.id, keepingContents: false) }
            Button("Delete Folder, Keep Its Folders") { library.deleteFolder(folder.id, keepingContents: true) }
        } else {
            Button("Delete Folder", role: .destructive) { library.deleteFolder(folder.id, keepingContents: false) }
        }
    }

    private func folderDeleteMessage(for folder: StickerFolder) -> String {
        let count = library.library.count(inTree: folder.id)
        let hasSubfolders = !library.library.children(of: folder.id).isEmpty
        guard count > 0 || hasSubfolders else { return String(localized: "The folder is empty.") }
        let destination = folder.parentID.flatMap { library.library.folder($0) }?.name
        let kept = destination.map { String(localized: "Keeping them moves them to “\($0)”.") }
            ?? String(localized: "Keeping them moves them to the top level.")
        return count > 0 ? String(localized: "Deleted stickers also disappear from Messages and the keyboard. \(kept)") : kept
    }

    #if DEBUG
    private func runDebugLaunchActions() {
        guard folderID == nil, !didRunDebugActions else { return }
        didRunDebugActions = true
        if let search = DebugLaunch.search { searchText = search }
        switch DebugLaunch.screen {
        case "select":
            isSelecting = true
            selection = Set(levelStickers.prefix(2).map(\.id))
        case "export-whatsapp", "export-telegram":
            isSelecting = true
            selection = Set(levelStickers.prefix(30).map(\.id))
            exportTarget = DebugLaunch.screen == "export-whatsapp" ? .whatsApp : .telegram
        default: break
        }
    }
    #endif
}
