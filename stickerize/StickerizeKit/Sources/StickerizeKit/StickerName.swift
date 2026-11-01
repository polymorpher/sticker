import Foundation
import UniformTypeIdentifiers

/// Turns an imported file's name into a sticker name ("funny_cat.png" → "funny cat").
public enum StickerName {
    /// Used when the file has no name, or only an automatically generated one.
    public static var fallback: String { String(localized: "Sticker") }

    /// The sticker name for a file name, or nil when the name carries no meaning: camera and screenshot names
    /// ("IMG_1234", "PXL_20260102_…", "Screenshot 2026-…"), temporary UUID names, hashes (WeChat names sticker files by
    /// their MD5), bare numbers, "image".
    public static func fromFileName(_ fileName: String?) -> String? {
        guard var name = fileName.map({ ($0 as NSString).lastPathComponent }), !name.isEmpty else { return nil }
        // Drop the extension only when it is an image or PDF type, so "v1.5 final" keeps its dot.
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image) || type.conforms(to: .pdf) {
            name = (name as NSString).deletingPathExtension
        }
        name = name.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, !isGenerated(name) else { return nil }
        return String(name.prefix(StickerSpec.maxNameLength))
    }

    private static let generatedPatterns: [NSRegularExpression] = [
        // Cameras, phones, drones and editors: IMG 1234, PXL 20260102 123456789, DSC01234, GOPR0001, MVIMG …
        #"^(img|image|pxl|dsc[fn]?|dji|gopr|gp|mvimg|pano|vid|mov|photo|pic|picture)[ -]?\d"#,
        #"^(screenshot|screen shot|simulator screenshot|screen recording)\b"#,
        #"^(image|photo|picture|untitled|unknown|download|file)( \d+)?$"#,
        #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
        // Hashes have digits and letters (a name of only a–f letters, like "facade", is a word).
        #"^(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{16,}$"#,
        #"^[\d .()-]+$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func isGenerated(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return generatedPatterns.contains { $0.firstMatch(in: name, range: range) != nil }
    }
}
