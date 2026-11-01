import StickerizeKit
import StickerLift
import SwiftUI

/// Walks through a batch of imported images, one editor per image. Used by the app and the Share extension.
struct StickerEditorFlow: View {
    let items: [ImportedImage]
    let store: StickerStore
    /// The folder the batch goes into (nil for the top level), and its path's names, to show where each sticker goes.
    var destination: UUID?
    var destinationPath: [String] = []
    /// Called with the number of stickers saved once the batch is finished or cancelled.
    let onFinish: (Int) -> Void

    @State private var index = 0
    @State private var saved = 0
    @State private var finished = false
    /// The batch's last saved sticker: each one goes right after it, so the batch keeps its own order.
    @State private var lastSaved: Sticker.ID?

    var body: some View {
        NavigationStack {
            if items.indices.contains(index) {
                let item = items[index]
                StickerEditorView(item: item, store: store, position: (index + 1, items.count),
                                  target: .init(folder: destination, path: item.folderPath, after: lastSaved),
                                  shownPath: destinationPath + item.folderPath,
                                  onSaved: { sticker in
                                      saved += 1
                                      lastSaved = sticker.id
                                      advance(from: item.id)
                                  },
                                  onSkip: { advance(from: item.id) },
                                  onCancel: finish)
                    .id(item.id)
            }
        }
    }

    /// Ignores callbacks from an item that is no longer on screen (e.g. a save that finished after a skip).
    private func advance(from id: ImportedImage.ID) {
        guard !finished, items.indices.contains(index), items[index].id == id else { return }
        if index + 1 < items.count { index += 1 } else { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish(saved)
    }
}

struct StickerEditorView: View {
    /// Where a saved sticker goes (see `StickerStore.add`).
    struct Target {
        var folder: UUID?
        var path: [String] = []
        var after: UUID?
    }

    let store: StickerStore
    let position: (Int, Int)
    let target: Target
    /// The folder names it will be saved in, from the top level; empty for the top level.
    let shownPath: [String]
    let onSaved: (Sticker) -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void

    @State private var model: StickerEditorModel
    @State private var showsSubjects = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, emoji }

    init(item: ImportedImage, store: StickerStore, position: (Int, Int), target: Target = Target(), shownPath: [String] = [],
         onSaved: @escaping (Sticker) -> Void, onSkip: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.store = store
        self.position = position
        self.target = target
        self.shownPath = shownPath
        self.onSaved = onSaved
        self.onSkip = onSkip
        self.onCancel = onCancel
        _model = State(initialValue: StickerEditorModel(item: item))
    }

    var body: some View {
        Form {
            Section {
                canvas
                    .listRowInsets(EdgeInsets())
                if model.analysis != nil, model.removeBackground, !model.isAnimationMode {
                    Picker("View", selection: $showsSubjects) {
                        Text("Sticker").tag(false)
                        Text("Pick Subjects").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            } footer: {
                statusText
            }

            if let analysis = model.analysis, model.removeBackground, analysis.instances.count > 1, !model.isAnimationMode {
                Section("Subjects") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(analysis.instances) { instance in
                                SubjectChip(instance: instance, isSelected: model.selected.contains(instance.id)) {
                                    model.toggle(instance.id)
                                }
                            }
                            if model.selected != analysis.allInstanceIDs {
                                Button("All") { model.selectAll() }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if model.animation != nil {
                Section {
                    Toggle("Keep Animation", isOn: $model.keepAnimation)
                } footer: {
                    Text(model.keepAnimation
                         ? "Saved as an animated GIF, kept whole. WhatsApp and Telegram packs get its first frame."
                         : "Saved as a still from the first frame, which you can cut out and outline.")
                }
            }

            if !model.isAnimationMode {
                Section {
                    // Shown off (and disabled) when Vision isn't available, so the switch matches what will be saved.
                    Toggle("Remove Background", isOn: Binding(get: { model.removeBackground && model.analysis != nil },
                                                              set: { model.removeBackground = $0 }))
                        .disabled(model.analysis == nil)
                    Toggle("Crop to Subject", isOn: $model.cropToSubject)
                    Picker("Outline", selection: $model.outline) {
                        ForEach(OutlineStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                }
            }

            Section {
                TextField("Name", text: $model.name)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .emoji }
                TextField("Emoji (for WhatsApp and Telegram)", text: $model.emoji)
                    .focused($focusedField, equals: .emoji)
                    .onChange(of: model.emoji) { _, newValue in
                        let emoji = String(newValue.filter(\.isEmojiCharacter).prefix(3))
                        if emoji != newValue { model.emoji = emoji }
                    }
                if !shownPath.isEmpty {
                    LabeledContent("Folder") {
                        Text(shownPath.joined(separator: " › "))
                            .accessibilityLabel(Text(shownPath.reversed().joined(separator: String(localized: ", in "))))
                    }
                }
            } footer: {
                Text("The name is what VoiceOver reads for the sticker.")
            }
        }
        .navigationTitle(position.1 > 1 ? String(localized: "Sticker \(position.0) of \(position.1)") : String(localized: "New Sticker"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .disabled(model.isSaving)
            }
            if position.0 < position.1 {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Skip This Image", action: onSkip)
                        .disabled(model.isSaving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        if let sticker = await save() { onSaved(sticker) }
                    }
                }
                .disabled(!model.canSave)
            }
        }
        .onDisappear { model.cancelPendingWork() }
        .task {
            await model.prepare()
            #if DEBUG
            if DebugLaunch.autoSave, let sticker = await save() { onSaved(sticker) }
            #endif
        }
        .alert("Couldn't Make the Sticker", isPresented: Binding(get: { model.errorMessage != nil },
                                                                set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .interactiveDismissDisabled()
    }

    private func save() async -> Sticker? {
        await model.save(to: store, in: target.folder, path: target.path, after: target.after)
    }

    @ViewBuilder
    private var canvas: some View {
        ZStack {
            CheckerboardBackground()
            if let loadError = model.loadError {
                ContentUnavailableView("Can't Open This Image", systemImage: "photo.badge.exclamationmark",
                                       description: Text(loadError))
            } else if model.isAnimationMode, let animated = model.animatedPreview {
                AnimatedStickerView(image: animated)
                    .padding(12)
                    .accessibilityLabel(Text("Animated sticker preview"))
            } else if showsSubjects, model.analysis != nil, model.removeBackground, let source = model.source {
                subjectPicker(source)
            } else if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .accessibilityLabel(Text("Sticker preview"))
            } else if model.nothingSelected {
                Text("Pick at least one subject")
                    .foregroundStyle(.secondary)
            }
            if model.loadError == nil, model.isRendering || model.isSaving || (isDetecting && !model.isAnimationMode) {
                ProgressView()
                    .controlSize(.large)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }

    private func subjectPicker(_ source: CGImage) -> some View {
        Image(decorative: source, scale: 1)
            .resizable()
            .scaledToFit()
            .overlay {
                if let overlay = model.overlay {
                    // The label map isn't the image's aspect ratio; stretching it over the image's frame lines it up.
                    Image(decorative: overlay, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            model.toggleInstance(atNormalizedPoint: CGPoint(x: location.x / geometry.size.width,
                                                                            y: location.y / geometry.size.height))
                        }
                }
            }
            .padding(12)
            .accessibilityElement()
            .accessibilityLabel(Text("Photo with detected subjects. Use the subject buttons below to choose."))
    }

    private var isDetecting: Bool {
        if case .detecting = model.subjects { true } else { false }
    }

    @ViewBuilder
    private var statusText: some View {
        if model.isAnimationMode, let animation = model.animation {
            Text("Animated: \(animation.frames.count) frames, \(animation.duration.formatted(.number.precision(.fractionLength(1)))) s.")
        } else {
            subjectStatusText
        }
    }

    @ViewBuilder
    private var subjectStatusText: some View {
        switch model.subjects {
        case .detecting:
            if model.loadError != nil {
                Text("Skip it, or cancel and try another file.")
            } else {
                model.source == nil ? Text("Opening…") : Text("Finding subjects…")
            }
        case let .found(analysis):
            if !model.removeBackground {
                Text("Using the whole image.")
            } else if showsSubjects {
                Text("Tap a subject to keep or drop it.")
            } else if analysis.instances.count == 1 {
                Text("Found 1 subject.")
            } else {
                Text("Found \(analysis.instances.count) subjects. Switch to Pick Subjects to choose which to keep.")
            }
        case let .unavailable(reason):
            Text(reason)
        }
    }
}

private struct SubjectChip: View {
    let instance: SubjectInstance
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let color = SubjectAnalysis.palette[(instance.id - 1) % SubjectAnalysis.palette.count]
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255))
                    .frame(width: 12, height: 12)
                Text("Subject \(instance.id)")
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            }
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .secondary)
        .accessibilityValue(isSelected ? Text("Kept") : Text("Dropped"))
    }
}

/// The transparent-pixel checkerboard behind sticker previews.
struct CheckerboardBackground: View {
    var squareSize: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let columns = Int((size.width / squareSize).rounded(.up))
            let rows = Int((size.height / squareSize).rounded(.up))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * squareSize, y: CGFloat(row) * squareSize,
                                      width: squareSize, height: squareSize)
                    context.fill(Path(rect), with: .color(Color.primary.opacity(0.08)))
                }
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityHidden(true)
    }
}

extension Character {
    /// Emoji such as "🐱", "👍🏽", "🇯🇵" or "❤️", but not digits or "#" (which are technically emoji-capable).
    var isEmojiCharacter: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}
