import StickerizeKit
import SwiftUI

/// Sends the selected stickers to WhatsApp or Telegram as a sticker pack, using each app's official import API.
struct ExportView: View {
    let messenger: StickerActions.Messenger
    let stickers: [Sticker]
    let onCancel: () -> Void
    let onExported: () -> Void

    @Environment(LibraryModel.self) private var library
    @State private var packName: String
    @State private var publisher = String(localized: "Made with Stickerize")
    @State private var exportTask: Task<Void, Never>?
    @State private var errorMessage: String?

    private var isExporting: Bool { exportTask != nil }

    /// `suggestedPackName`: the WhatsApp pack's starting name (the folder the stickers are in).
    init(messenger: StickerActions.Messenger, stickers: [Sticker], suggestedPackName: String? = nil,
         onCancel: @escaping () -> Void, onExported: @escaping () -> Void) {
        self.messenger = messenger
        self.stickers = stickers
        self.onCancel = onCancel
        self.onExported = onExported
        _packName = State(initialValue: suggestedPackName ?? String(localized: "My Stickers"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Stickers", value: "\(stickers.count)")
                    if messenger == .whatsApp {
                        TextField("Pack Name", text: $packName)
                        TextField("Publisher", text: $publisher)
                    }
                } footer: {
                    Text(footer)
                }
                if !stickers.allSatisfy({ !($0.emoji ?? "").isEmpty }) {
                    Section {
                        Label("Stickers without an emoji get 🙂. Add emoji on each sticker's page to make them easier to find in \(messenger.name).",
                              systemImage: "face.smiling")
                            .font(.footnote)
                    }
                }
                if stickers.contains(where: \.isAnimated) {
                    Section {
                        Label("Animated stickers are added as still images (their first frame).", systemImage: "photo")
                            .font(.footnote)
                    }
                }
                if !messenger.isInstalled {
                    Section {
                        Label("\(messenger.name) doesn't seem to be installed.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Add to \(messenger.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Stops the export before it touches the pasteboard or opens the messenger.
                        exportTask?.cancel()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button("Add") { export() }
                            .disabled(!canExport)
                    }
                }
            }
            .interactiveDismissDisabled(isExporting)
            .alert("Couldn't Add the Stickers", isPresented: Binding(get: { errorMessage != nil },
                                                                    set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var footer: String {
        switch messenger {
        case .whatsApp:
            String(localized: "WhatsApp packs hold 3 to 30 stickers. Each is converted to a 512 × 512 WebP, and WhatsApp asks you to confirm.")
        case .telegram:
            String(localized: "Telegram creates a new sticker set from these (up to 120) and asks you to name it.")
        }
    }

    private var canExport: Bool {
        messenger.allowedCount.contains(stickers.count)
            && (messenger != .whatsApp || (!packName.trimmingCharacters(in: .whitespaces).isEmpty
                && !publisher.trimmingCharacters(in: .whitespaces).isEmpty))
    }

    private func export() {
        exportTask = Task {
            defer { exportTask = nil }
            do {
                try await StickerActions.export(stickers, from: library.store, to: messenger, packName: packName, publisher: publisher)
                onExported()
            } catch is CancellationError {
                // Cancelled from the toolbar; the sheet is already closing.
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
