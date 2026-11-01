import StickerizeKit
import SwiftUI

/// Picks where to move stickers or a folder: the top level or any folder, shown as an indented tree. A new folder can
/// be made inside the one highlighted.
struct FolderPicker: View {
    let title: String
    /// Where the items are now: `.some(nil)` for the top level, `.none` when they're in different places.
    let current: UUID??
    /// Folders that can't be picked: a folder being moved and everything inside it.
    let excluded: Set<UUID>
    /// Makes the move; an error it throws is shown here and the picker stays open.
    let onPick: (UUID?) throws -> Void

    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newFolderParent: UUID??
    @State private var newFolderName = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                row(name: String(localized: "Top Level"), systemImage: "square.grid.2x2", depth: 0, folder: nil)
                ForEach(library.library.outline(), id: \.folder.id) { entry in
                    row(name: entry.folder.name, systemImage: "folder", depth: entry.depth + 1, folder: entry.folder.id)
                        // Indentation is visual only; say where same-named folders are.
                        .accessibilityValue(Text(library.library.path(to: entry.folder.parentID).map(\.name)
                            .map { String(localized: "in \($0)") }.joined(separator: ", ")))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        newFolderParent = .some(nil)
                    }
                }
            }
            .alert("New Folder", isPresented: Binding(get: { newFolderParent != nil }, set: { if !$0 { newFolderParent = nil } })) {
                TextField("Name", text: $newFolderName)
                Button("Cancel", role: .cancel) {}
                Button("Create and Move") {
                    guard case let .some(parent) = newFolderParent else { return }
                    do {
                        let folder = try library.attempt { try library.store.createFolder(named: newFolderName, in: parent) }
                        pick(folder.id)
                    } catch {
                        // After this alert has gone, or the next one wouldn't show.
                        Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            show(error)
                        }
                    }
                }
            } message: {
                Text(newFolderParent.flatMap { $0 }.flatMap { library.library.folder($0)?.name }
                    .map { String(localized: "It's made inside “\($0)”.") } ?? String(localized: "It's made at the top level."))
            }
            .alert("Couldn't Move", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func row(name: String, systemImage: String, depth: Int, folder: UUID?) -> some View {
        let isExcluded = folder.map(excluded.contains) ?? false
        let isCurrent = current == .some(folder)
        return Button {
            pick(folder)
        } label: {
            HStack {
                Label(name, systemImage: systemImage)
                    .padding(.leading, CGFloat(min(depth, 6)) * 16)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(isExcluded ? .secondary : .primary)
        .disabled(isExcluded || isCurrent)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .swipeActions(edge: .trailing) {
            if !isExcluded {
                Button("New Folder Inside", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    newFolderParent = .some(folder)
                }
                .tint(.accentColor)
            }
        }
    }

    private func pick(_ folder: UUID?) {
        do {
            try onPick(folder)
            dismiss()
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
