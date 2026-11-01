#if DEBUG
import Foundation

/// Debug-build launch arguments that drive the real screens, for simulator checks and screenshots where XCUITest
/// can't run. Compiled out of Release builds.
///
///     xcrun simctl launch booted ai.qokka.stickerize \
///         -StickerizeDebugReset YES -StickerizeDebugImport "/path/a.jpg|/path/b.png" -StickerizeDebugAutoSave YES
///
/// - `-StickerizeDebugReset YES`: delete every sticker first.
/// - `-StickerizeDebugImport "<path>|<path>"`: open the editor on these files (simulator processes can read host paths).
/// - `-StickerizeDebugAutoSave YES`: save each editor item as soon as subject detection finishes.
/// - `-StickerizeDebugScreen detail|setup|folder|select|export-whatsapp|export-telegram`: open a screen after launch
///   (`folder`: the first top-level folder).
/// - `-StickerizeDebugSearch <text>`: search the library for this.
/// - `-StickerizeDebugFocus YES`: focus the name field on the detail screen, which brings up the keyboard.
/// - `-StickerizeDebugCopy YES`: copy the first sticker the way the Copy action does (check with `simctl pbsync`).
enum DebugLaunch {
    private static var defaults: UserDefaults { .standard }

    static var reset: Bool { defaults.bool(forKey: "StickerizeDebugReset") }
    static var importPaths: [String] {
        defaults.string(forKey: "StickerizeDebugImport")?.split(separator: "|").map(String.init) ?? []
    }
    static var autoSave: Bool { defaults.bool(forKey: "StickerizeDebugAutoSave") }
    static var screen: String? { defaults.string(forKey: "StickerizeDebugScreen") }
    static var search: String? { defaults.string(forKey: "StickerizeDebugSearch") }
    static var focus: Bool { defaults.bool(forKey: "StickerizeDebugFocus") }
    static var copy: Bool { defaults.bool(forKey: "StickerizeDebugCopy") }
}
#endif
