// stickerize: lift any subjects out of a photo into a sticker-ready transparent PNG, choosing exactly which
// instances to keep (Photos' "Add Sticker" only takes its main subject). Same pipeline as the iOS app.
// Also: `stickerize signal-pack <folder or zip>` converts a sticker collection (e.g. WeChat exports) into Signal Desktop packs.

import CoreGraphics
import Foundation
import StickerizeKit
import StickerLift
import StickerExport

let usage = """
usage: stickerize <image> [options]
       stickerize signal-pack <folder-or-zip> --output <dir> [options]

Subject lift (single image):
  --list               list detected instances (id, area %, bbox in image pixels) and exit
  --include 1,3        keep only these instance ids (default: all)
  --output PATH        where to write the PNG (default: <image name>-sticker.png next to the input)
  --keep-background    don't remove the background (just crop/outline/normalize)
  --no-crop            keep the full canvas instead of trimming to the subject
  --outline PX         add a white outline about PX pixels wide on the final sticker
  --max-size PX        longest side of the output (default \(StickerSpec.maxPixelDimension))
  --max-bytes N        PNG size limit in bytes (default \(StickerSpec.maxFileBytes))
  --full-size          skip size normalization (writes the cut-out at working resolution, up to 4096 px)
  -h, --help           show this help

By default the output meets MSSticker's rules: canvas between \(StickerSpec.minPixelDimension) and \(StickerSpec.maxPixelDimension) px per side
(small subjects are scaled up at most \(Int(StickerSpec.maxUpscale))× and centred on transparent padding), PNG ≤ \(StickerSpec.maxFileBytes / 1000) KB.

Input can be anything ImageIO reads (JPEG, HEIC, PNG, WebP, …) or a PDF (page 1). EXIF orientation is applied.
Exit status: 0 success, 1 error, 2 usage error, 3 no subject found / background removal unavailable.

Signal pack (folder or ZIP → Signal Desktop):
  --output DIR         required; must be outside the input, which is never written to
  --replace            move the pack-NN folders an earlier run left in DIR to the Trash (otherwise the run stops)
  --max-per-pack N     stickers per pack folder, 1–\(SignalPackExport.stickerCount.upperBound) (default \(SignalPackExport.stickerCount.upperBound))

Converts GIF/JPG/PNG/WebP/APNG and any other image ImageIO reads (e.g. WeChat favorites from export-wechat-emoji)
into Signal stickers, split into pack-01, pack-02, … The input is a folder or a ZIP archive; subfolders and ZIP
archives inside it are searched too, and files without an extension are recognized by their contents. Stills become \(SignalPackExport.pixelDimension) px PNGs (Signal re-encodes them; they're checked to fit its
\(SignalPackExport.maxFileBytes / 1024) KB limit). Animations become square APNGs of up to \(SignalPackExport.pixelDimension) px and \(SignalPackExport.maxFileBytes / 1024) KB that loop forever, as
Signal requires; one that is too big is reduced to 256 colors, then shrunk and thinned, and kept as a still if it
still can't fit. Every reduced sticker is listed.
Upload each pack folder in Signal Desktop: File → Create/upload sticker pack.
"""

struct UsageError: Error { let message: String }
struct RunError: LocalizedError { let errorDescription: String? }

struct Options {
    var input = ""
    var list = false
    var include: IndexSet?
    var output: String?
    var keepBackground = false
    var crop = true
    var outlinePixels = 0.0
    var maxSize = StickerSpec.maxPixelDimension
    var maxBytes = StickerSpec.maxFileBytes
    var fullSize = false
}

struct SignalPackOptions {
    var input = ""
    var outputDirectory = ""
    var maxPerPack = SignalPackExport.stickerCount.upperBound
    var replace = false
}

/// Best effort: a closed terminal or pipe mustn't crash the run (or its cleanup) over a message.
func log(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

/// For testing a signal that comes while packs are installed: with STICKERIZE_TEST_HOLD_INSTALL set to a path, the run
/// creates that file once it can no longer be stopped, and waits (a minute at most) until it is removed.
func holdBeforeInstallingForTests() {
    guard let path = ProcessInfo.processInfo.environment["STICKERIZE_TEST_HOLD_INSTALL"] else { return }
    FileManager.default.createFile(atPath: path, contents: nil)
    for _ in 0..<600 where FileManager.default.fileExists(atPath: path) { usleep(100_000) }
}

func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    func value(for flag: String) throws -> String {
        guard let value = iterator.next(), !value.hasPrefix("--") else { throw UsageError(message: "\(flag) needs a value") }
        return value
    }
    func positiveInt(_ text: String, _ flag: String) throws -> Int {
        guard let number = Int(text), number > 0 else { throw UsageError(message: "\(flag) needs a positive integer, got \"\(text)\"") }
        return number
    }
    while let argument = iterator.next() {
        switch argument {
        case "-h", "--help": print(usage); exit(0)
        case "--list": options.list = true
        case "--include":
            let text = try value(for: argument)
            var ids = IndexSet()
            for part in text.split(separator: ",", omittingEmptySubsequences: false) {
                ids.insert(try positiveInt(String(part).trimmingCharacters(in: .whitespaces), "--include"))
            }
            options.include = ids
        case "--output": options.output = try value(for: argument)
        case "--keep-background": options.keepBackground = true
        case "--no-crop": options.crop = false
        case "--crop": options.crop = true // the original tool's flag; cropping is now the default
        case "--outline":
            let text = try value(for: argument)
            guard let pixels = Double(text), pixels >= 0, pixels.isFinite else { throw UsageError(message: "--outline needs a number ≥ 0") }
            options.outlinePixels = pixels
        case "--max-size": options.maxSize = try positiveInt(try value(for: argument), argument)
        case "--max-bytes": options.maxBytes = try positiveInt(try value(for: argument), argument)
        case "--full-size": options.fullSize = true
        case "--scale": throw UsageError(message: "--scale was replaced by --max-size PX (output is resampled with high quality)")
        default:
            if argument.hasPrefix("-") { throw UsageError(message: "unknown option \(argument)") }
            guard options.input.isEmpty else { throw UsageError(message: "only one input image is supported") }
            options.input = argument
        }
    }
    guard !options.input.isEmpty else { throw UsageError(message: "missing input image") }
    if options.keepBackground, options.include != nil { throw UsageError(message: "--include can't be combined with --keep-background") }
    return options
}

func parseSignalPack(_ arguments: [String]) throws -> SignalPackOptions {
    var options = SignalPackOptions()
    var iterator = arguments.makeIterator()
    func value(for flag: String) throws -> String {
        guard let value = iterator.next(), !value.hasPrefix("--") else { throw UsageError(message: "\(flag) needs a value") }
        return value
    }
    while let argument = iterator.next() {
        switch argument {
        case "-h", "--help": print(usage); exit(0)
        case "--output": options.outputDirectory = try value(for: argument)
        case "--replace": options.replace = true
        case "--max-per-pack":
            let text = try value(for: argument)
            guard let n = Int(text), SignalPackExport.stickerCount.contains(n) else {
                throw UsageError(message: "--max-per-pack needs a number from 1 to \(SignalPackExport.stickerCount.upperBound) (Signal's limit), got \"\(text)\"")
            }
            options.maxPerPack = n
        default:
            if argument.hasPrefix("-") { throw UsageError(message: "unknown option \(argument)") }
            guard options.input.isEmpty else { throw UsageError(message: "only one input folder or ZIP archive is supported") }
            options.input = argument
        }
    }
    guard !options.input.isEmpty else { throw UsageError(message: "missing input folder or ZIP archive") }
    guard !options.outputDirectory.isEmpty else { throw UsageError(message: "--output DIR is required (never writes into the input)") }
    // Where the output may go relative to the input is checked by SignalPackExport.writePacks.
    return options
}

let workingMaxPixelSize = 4096

func defaultOutput(for input: String) -> String {
    let url = URL(fileURLWithPath: input)
    return url.deletingPathExtension().path + "-sticker.png"
}

func run(_ options: Options) throws {
    let inputURL = URL(fileURLWithPath: options.input)
    // Work at ≤ 4096 px: plenty for a ≤ 618 px sticker, and it bounds memory (the original tool peaked at 1.4 GB on an
    // 8000 px photo) and avoids Vision's failure above 16384 px. --list scales boxes back to the input's own pixels.
    let image = try ImageLoader.image(contentsOf: inputURL, maxPixelSize: workingMaxPixelSize)
    let original = ImageLoader.orientedPixelSize(contentsOf: inputURL) ?? CGSize(width: image.width, height: image.height)
    let listScale = Double(max(original.width, original.height)) / Double(max(image.width, image.height))
    log("input: \(Int(original.width))×\(Int(original.height)) px" + (listScale > 1 ? ", working at \(image.width)×\(image.height)" : ""))

    var analysis: SubjectAnalysis?
    if !options.keepBackground {
        let result = try SubjectLifter.analyze(image)
        analysis = result
        log("instances detected: \(result.instances.map(\.id))")
        if options.list {
            print("id  area%   bbox (px, top-left origin)")
            for instance in result.instances {
                let box = instance.boundingBox.applying(CGAffineTransform(scaleX: listScale, y: listScale))
                print(String(format: "%2d  %5.1f  x:%.0f y:%.0f w:%.0f h:%.0f", instance.id, instance.areaFraction * 100,
                             box.minX, box.minY, box.width, box.height))
            }
            return
        }
        if let include = options.include {
            let missing = include.subtracting(result.allInstanceIDs)
            guard missing.isEmpty else {
                throw RunError(errorDescription: "instance \(missing.map(String.init).joined(separator: ",")) not detected; detected: \(result.instances.map(\.id))")
            }
        }
    } else if options.list {
        throw UsageError(message: "--list needs background removal (drop --keep-background)")
    }

    let recipe = StickerRecipe(removeBackground: !options.keepBackground, instances: options.include, cropToSubject: options.crop)
    var rendered = try StickerMaker.render(image, analysis: analysis, recipe: recipe)
    if options.outlinePixels > 0 {
        // --outline is in output pixels, so convert through the scale the encoder will apply (1 with --full-size;
        // up to 3× for small subjects).
        // The outline grows the canvas by (width + 2) per side, so solve s·(L + 2·(px/s + 2)) = maxSize for s.
        let longest = Double(max(rendered.width, rendered.height))
        let fitted = (Double(options.maxSize) - 2 * options.outlinePixels) / (longest + 4)
        let outputScale = options.fullSize ? 1 : max(0.01, min(fitted, StickerSpec.maxUpscale))
        rendered = try StickerOutline.apply(to: rendered, width: options.outlinePixels / outputScale)
    }
    let png: Data
    let size: (Int, Int)
    if options.fullSize {
        png = try StickerEncoder.pngData(ImageOps.redraw(rendered, width: rendered.width, height: rendered.height) ?? rendered)
        size = (rendered.width, rendered.height)
    } else {
        let canvas = StickerCanvas(maxPixelDimension: options.maxSize, minPixelDimension: StickerSpec.minPixelDimension,
                                   maxUpscale: StickerSpec.maxUpscale, maxBytes: options.maxBytes)
        let encoded = try StickerEncoder.encode(rendered, canvas: canvas)
        png = encoded.data
        size = (encoded.pixelWidth, encoded.pixelHeight)
    }
    let output = options.output ?? defaultOutput(for: options.input)
    try png.write(to: URL(fileURLWithPath: output), options: .atomic)
    log("wrote \(size.0)×\(size.1) px, \(png.count / 1000) KB")
    print(output)
}

func runSignalPack(_ options: SignalPackOptions) throws {
    let input = URL(fileURLWithPath: options.input)
    let output = URL(fileURLWithPath: options.outputDirectory, isDirectory: true)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDir) else {
        throw RunError(errorDescription: "input doesn't exist: \(input.path)")
    }
    guard isDir.boolValue || ImageFinder.isArchive(input) else {
        throw RunError(errorDescription: "input must be a folder or a ZIP archive: \(input.path)")
    }
    let report: SignalPackExport.Report
    // Writing to a closed terminal or pipe fails instead of killing the process before it cleans up.
    signal(SIGPIPE, SIG_IGN)
    let signals = stopCleanlyOnSignals()
    defer { restoreSignals(signals) }
    do {
        report = try SignalPackExport.writePacks(from: input, to: output, maxPerPack: options.maxPerPack,
                                                 replacingExisting: options.replace, movingReplacedToTrash: true,
                                                 willInstall: holdBeforeInstallingForTests)
    } catch let SignalPackError.outputHasPacks(names) {
        throw RunError(errorDescription: "\(output.path) already has \(names.joined(separator: ", ")) from an earlier run. "
            + "Pass --replace to move them to the Trash first, or choose another folder.")
    } catch let error as SignalPackError {
        switch error {
        case let .nothingConverted(skipped), let .tooLargeToUnpack(_, _, _, skipped):
            for skip in skipped { log("  skipped \(ImageFinder.displayPath(skip.name)): \(skip.reason)") }
        default: break
        }
        throw error
    }
    let stickers = report.packs.flatMap(\.stickers)
    log("converted \(stickers.count) sticker(s) into \(report.packs.count) pack(s); skipped \(report.skipped.count)"
        + (report.otherFiles > 0 ? "; left out \(report.otherFiles) file(s) that aren't images" : ""))
    for skip in report.skipped {
        log("  skipped \(ImageFinder.displayPath(skip.name)): \(skip.reason)")
    }
    if report.reachedImageLimit {
        log("stopped at \(ImageFinder.Limits().maxImages.formatted()) images; convert the rest from a smaller folder or archive")
    }
    if report.leftOutAtByteLimit > 0, let first = report.firstLeftOutAtByteLimit {
        let limit = ByteCountFormatter.string(fromByteCount: Int64(ImageFinder.Limits().maxTotalBytes), countStyle: .memory)
        log("left out \(report.leftOutAtByteLimit) file(s) from \(ImageFinder.displayPath(first)) on: unpacking them would take more than \(limit), "
            + "the most one run unpacks; unzip the archive and convert the folder instead")
    }
    let reduced = stickers.filter(\.info.wasReduced)
    if !reduced.isEmpty {
        log("reduced to fit Signal's limits (worth a look before uploading):")
        for sticker in reduced {
            let path = sticker.fileURL.pathComponents.suffix(2).joined(separator: "/")
            log("  \(path) (from \(ImageFinder.displayPath(sticker.info.sourceName))): \(describeReduction(sticker.info))")
        }
    }
    for pack in report.packs {
        let animated = pack.stickers.filter(\.info.animated).count
        log("\(pack.directory.path): \(pack.stickers.count) files (\(animated) animated APNG)")
        print(pack.directory.path)
    }
    log("""
    Next: open Signal Desktop → File → Create/upload sticker pack → drag in one pack folder's files.
    Assign an emoji per sticker, set title/author, Upload, then Install.
    Docs: https://support.signal.org/hc/en-us/articles/360031836512-Stickers
    """)
    // A signal that came while the packs were being installed: they are in place and listed above; now stop as asked.
    if let number = SignalPackExport.takeDeferredSignal() {
        log("interrupted after the packs were installed")
        restoreSignals(signals)
        raiseDefault(number)
    }
}

/// Signals handled while a run is in progress, and how each was handled before.
struct HandledSignals {
    var sources: [any DispatchSourceSignal] = []
    var numbers: [Int32] = []
}

/// Ctrl-C, a kill or a closed terminal would skip the run's cleanup and leave up to 2 GB of unpacked images behind.
/// Instead the run is asked to stop: it does so at its next file (or chunk, while unpacking) and removes its temporary
/// files. Meanwhile a second Ctrl-C or kill ends the process at once; another hangup doesn't, as closing a terminal
/// running zsh sends two. Then the process dies of the signal, so a shell script running it stops too. If the run was
/// already installing its packs, it finishes and reports first.
/// Signals the process inherited as ignored (`nohup`, background jobs of a script) stay ignored.
func stopCleanlyOnSignals() -> HandledSignals {
    var handled = HandledSignals()
    handled.numbers = [SIGINT, SIGTERM, SIGHUP].filter { !isIgnore(signal($0, SIG_IGN)) }
    let numbers = handled.numbers
    // One queue for all of them: once one is stopping the run, the others wait (a second Ctrl-C or kill meanwhile goes
    // to the system's default handler, which quits at once).
    let queue = DispatchQueue(label: "signals")
    handled.sources = numbers.map { number in
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler {
            if SignalPackExport.cancelRuns(deferring: number) {
                return // installing: the run finishes, prints its report, then stops (see runSignalPack)
            }
            // What quits at once now: the same again, except a hangup (a closed terminal sends two).
            let ctrlC = "; press Ctrl-C again to quit at once", kill = "; kill it again to quit at once"
            let hint = number == SIGINT ? ctrlC : number == SIGTERM ? kill
                : numbers.contains(SIGINT) ? ctrlC : numbers.contains(SIGTERM) ? kill : ""
            log("stopping and removing temporary files" + hint)
            for other in numbers where other != SIGHUP { signal(other, SIG_DFL) }
            SignalPackExport.waitForRuns()
            raiseDefault(number)
        }
        source.resume()
        return source
    }
    return handled
}

func restoreSignals(_ handled: HandledSignals) {
    for source in handled.sources { source.cancel() }
    for number in handled.numbers { signal(number, SIG_DFL) }
}

func isIgnore(_ handler: sig_t?) -> Bool {
    unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
}

/// Dies of `number`, as if it had never been handled, after writing out what was printed.
func raiseDefault(_ number: Int32) -> Never {
    fflush(stdout)
    signal(number, SIG_DFL)
    kill(getpid(), number)
    sleep(1)
    _exit(128 + number)
}

func describeReduction(_ info: SignalPackExport.StickerInfo) -> String {
    let size = "\(info.pixelWidth)×\(info.pixelHeight) px" + (info.shrunk ? " (shrunk)" : "")
    if info.isStillFallback {
        return "kept as a still, \(size): the \(info.sourceFrameCount)-frame animation can't fit even small and at a low frame rate"
    }
    var parts = [size]
    if info.frameCount < info.sourceFrameCount { parts.append("\(info.frameCount) of \(info.sourceFrameCount) frames") }
    if info.colorsReduced { parts.append("256 colors") }
    return parts.joined(separator: ", ")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.first == "signal-pack" {
        try runSignalPack(try parseSignalPack(Array(args.dropFirst())))
    } else {
        try run(try parse(args))
    }
} catch is CancellationError {
    // Stopped by a signal: its handler ends the process once the run has cleaned up.
    while true { pause() }
} catch let error as UsageError {
    log("error: \(error.message)\n\n\(usage)")
    exit(2)
} catch let error as SubjectLiftError {
    log("error: \(error.localizedDescription)")
    switch error {
    case .noSubjects, .unavailable: exit(3)
    default: exit(1)
    }
} catch {
    log("error: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
    exit(1)
}
