import StickerizeKit
import SwiftUI

/// Where stickers show up, and the one-time setup for the keyboard.
struct SetupGuideView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Step(number: 1, text: "In any app, open the emoji keyboard and tap Stickers. Stickerize has its own tab there.")
                    Step(number: 2, text: "In Messages, tap + and choose Stickers, then Stickerize. Tap a sticker to add it, or touch and hold to peel it onto a message.")
                    Step(number: 3, text: "Tap the name at the top to show one folder, or the magnifying glass to search by name, emoji or folder.")
                } header: {
                    Label("Messages and the Emoji Keyboard", systemImage: "message")
                } footer: {
                    Text("New stickers appear there as soon as you save them. In apps other than Messages, a sticker is inserted as an image where the app accepts images.")
                }

                Section {
                    Step(number: 1, text: "Open Settings › General › Keyboard › Keyboards › Add New Keyboard and choose Stickerize.")
                    Step(number: 2, text: "Tap Stickerize in that list and turn on Allow Full Access. It's needed to copy stickers; Stickerize has no network code and never sees what you type elsewhere.")
                    Step(number: 3, text: "In a chat, switch to the Stickerize keyboard with the globe key, tap a sticker, then touch and hold the message field and tap Paste.")
                    Step(number: 4, text: "To find a sticker, type a word such as “cat” before switching: the keyboard shows the stickers that match it.")
                    Button("Open Settings", systemImage: "gear") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } header: {
                    Label("Stickerize Keyboard (WhatsApp, Telegram, Signal…)", systemImage: "keyboard")
                } footer: {
                    Text("Telegram sends a pasted transparent sticker as a sticker; other apps may send it as an image.")
                }

                Section {
                    Step(number: 1, text: "Tap Select, choose 3 to 30 stickers, then tap Add to… › WhatsApp (or up to 120 for Telegram).")
                    Step(number: 2, text: "Confirm in WhatsApp or Telegram. The pack then lives in that app's own sticker picker.")
                } header: {
                    Label("WhatsApp and Telegram Packs", systemImage: "square.and.arrow.up.on.square")
                }

                Section {
                    Step(number: 1, text: "Open a sticker and tap Save to Photos, or tap Select, choose several, then Add to… › Save to Photos.")
                    Step(number: 2, text: "In Photos, open it, touch and hold the subject, then tap Add Sticker. iOS cuts the subject out again, so very thin parts may be trimmed.")
                    Step(number: 3, text: "Send it from your own stickers in the Stickers drawer. People you send it to can touch and hold it and tap Save to Stickers, or Sticker Details › Save if it was placed on a message (iOS 17.2 or later).")
                } header: {
                    Label("Stickers Friends Can Save", systemImage: "photo.on.rectangle")
                } footer: {
                    Text("Apps can't add to your iPhone's sticker library directly; this is the way iOS offers. iOS lets people save only stickers made on the sender's iPhone: for a sticker sent from the Stickerize tab, Sticker Details only shows which app it came from.")
                }

                Section("Storage") {
                    switch library.store.location {
                    case let .appGroup(identifier):
                        LabeledContent("Shared library", value: identifier)
                    case .local:
                        StorageWarning()
                    }
                    LabeledContent("Stickers", value: "\(library.stickers.count)")
                }
            }
            .navigationTitle("How to Use")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}
