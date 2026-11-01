import StickerizeKit
import SwiftUI

struct StickerDetailView: View {
    let stickerID: Sticker.ID
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = ""
    @State private var image: UIImage?
    @State private var confirmsDelete = false
    @State private var showsMove = false
    @State private var status: String? {
        didSet { if let status { AccessibilityNotification.Announcement(status).post() } }
    }
    @FocusState private var nameFocused: Bool

    private var sticker: Sticker? { library.stickers.first { $0.id == stickerID } }

    var body: some View {
        if let sticker {
            content(for: sticker)
        } else {
            ContentUnavailableView("Sticker Deleted", systemImage: "trash")
        }
    }

    private func content(for sticker: Sticker) -> some View {
        Form {
            Section {
                ZStack {
                    CheckerboardBackground()
                    if let image, sticker.isAnimated {
                        AnimatedStickerView(image: image)
                            .padding(16)
                            .accessibilityLabel(Text(sticker.name))
                    } else if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(16)
                            .accessibilityLabel(Text(sticker.name))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("\(sticker.pixelWidth) × \(sticker.pixelHeight) px · \(sticker.byteCount / 1000) KB · \(sticker.format.rawValue.uppercased())")
            }

            Section {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .onSubmit { save(sticker) }
                TextField("Emoji (for WhatsApp and Telegram)", text: $emoji)
                    .onChange(of: emoji) { _, newValue in
                        let filtered = String(newValue.filter(\.isEmojiCharacter).prefix(3))
                        if filtered != newValue { emoji = filtered }
                    }
                    .onSubmit { save(sticker) }
                Button {
                    showsMove = true
                } label: {
                    LabeledContent("Folder") {
                        let path = library.library.path(to: sticker.folderID).map(\.name)
                        Text(path.isEmpty ? String(localized: "Top Level") : path.joined(separator: " › "))
                    }
                }
                .accessibilityHint(Text("Moves the sticker to another folder"))
            }

            Section {
                Button("Copy", systemImage: "doc.on.doc") {
                    do {
                        try StickerActions.copy(sticker, from: library.store)
                        status = String(localized: "Copied. Paste it into any app that takes images.")
                    } catch {
                        library.show("Couldn't Copy", error)
                    }
                }
                StickerShareLink(sticker: sticker, store: library.store)
                Button("Save to Photos", systemImage: "photo.badge.plus") {
                    Task {
                        do {
                            try await StickerActions.saveToPhotos(sticker, from: library.store)
                            status = String(localized: "Saved. To add it to your iPhone stickers too, open it in Photos, touch and hold the subject, then tap Add Sticker. Stickers sent from your iPhone stickers can be saved by the people you send them to.")
                        } catch {
                            library.show("Couldn't Save to Photos", error)
                        }
                    }
                }
                Button("Move to Front", systemImage: "arrow.up.to.line") { library.moveToFront(sticker) }
            } footer: {
                if let status { Text(status) }
            }

            Section {
                Button("Delete Sticker", systemImage: "trash", role: .destructive) { confirmsDelete = true }
            }
        }
        .navigationTitle(sticker.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = sticker.name
            emoji = sticker.emoji ?? ""
            #if DEBUG
            if DebugLaunch.focus { nameFocused = true }
            #endif
        }
        .onDisappear { save(sticker) }
        .task(id: sticker.id) {
            let url = library.store.fileURL(for: sticker)
            let animated = sticker.isAnimated
            image = await Task.detached {
                if animated, let frames = try? AnimatedImageLoader.frames(contentsOf: url) {
                    return frames.playableImage()
                }
                return ImageLoader.thumbnail(contentsOf: url, maxPixelSize: 1024).map { UIImage(cgImage: $0) }
            }.value
        }
        .sheet(isPresented: $showsMove, onDismiss: library.presentMessageAgain) {
            FolderPicker(title: String(localized: "Move Sticker"), current: .some(sticker.folderID), excluded: []) { folder in
                try library.attempt { try library.store.move([sticker.id], to: folder) }
            }
        }
        .confirmationDialog("Delete this sticker?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete([sticker.id])
                dismiss()
            }
        }
    }

    private func save(_ sticker: Sticker) {
        guard library.stickers.contains(where: { $0.id == sticker.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != sticker.name || emoji != (sticker.emoji ?? "") else { return }
        library.update(sticker, name: trimmed, emoji: emoji)
    }
}
