import StickerizeKit
import UIKit

/// The folder chooser of the iMessage app and the keyboard: "All Stickers", then every folder as an indented tree, each
/// with how many stickers it holds. A vertical list inside the extension's own view, so it works at any depth, in the
/// Messages drawer, the emoji keyboard and a keyboard alike, where a menu could be cut off.
final class FolderScopeList: UIView, UITableViewDataSource, UITableViewDelegate {
    /// Called with the picked folder (nil for all stickers).
    var onPick: ((UUID?) -> Void)?
    /// Room left at the bottom for a control drawn over the list (the keyboard's globe key).
    var bottomInset: CGFloat = 0 {
        didSet {
            tableView.contentInset.bottom = bottomInset
            tableView.verticalScrollIndicatorInsets.bottom = bottomInset
        }
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    /// `location`: the folders it's in, for VoiceOver, which doesn't see the indentation.
    private var rows: [(folder: StickerFolder?, depth: Int, count: Int, location: String)] = []
    private var current: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ library: StickerLibrary, current: UUID?) {
        self.current = current
        rows = [(nil, 0, library.stickers.count, "")]
            + library.outline().map { entry in
                (folder: entry.folder, depth: entry.depth + 1, count: library.count(inTree: entry.folder.id),
                 location: library.path(to: entry.folder.parentID).map(\.name).joined(separator: ", "))
            }
        tableView.reloadData()
        if let index = rows.firstIndex(where: { $0.folder?.id == current }) {
            tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: false)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let row = rows[indexPath.row]
        var content = UIListContentConfiguration.valueCell()
        content.text = row.folder?.name ?? String(localized: "All Stickers")
        content.secondaryText = row.count.formatted()
        content.image = UIImage(systemName: row.folder == nil ? "square.grid.2x2" : "folder")
        content.textProperties.numberOfLines = 1
        content.directionalLayoutMargins.leading = CGFloat(min(row.depth, 6)) * 16
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        let isCurrent = row.folder?.id == current
        cell.accessoryType = isCurrent ? .checkmark : .none
        cell.accessibilityTraits = isCurrent ? [.button, .selected] : .button
        let count = row.count == 1 ? String(localized: "1 sticker") : String(localized: "\(row.count) stickers")
        cell.accessibilityLabel = "\(row.folder?.name ?? String(localized: "All Stickers")), \(count)"
        cell.accessibilityValue = row.location.isEmpty ? nil : String(localized: "in \(row.location)")
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onPick?(rows[indexPath.row].folder?.id)
    }
}

/// The header button that names the folder being shown and opens `FolderScopeList`. Its text follows the text size up
/// to a cap, so it can't push the stickers out of a short drawer.
final class FolderScopeButton: UIButton {
    private var path: [String] = []
    private var isOpen = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small))
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        configuration.titleLineBreakMode = .byTruncatingMiddle
        self.configuration = configuration
        showsLargeContentViewer = true
        addInteraction(UILargeContentViewerInteraction())
        contentHorizontalAlignment = .leading
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (button: FolderScopeButton, _) in
            button.update(path: button.path, isOpen: button.isOpen)
        }
        update(path: [], isOpen: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `path`: the folder shown and the folders it's in, from the top level; empty for all stickers.
    func update(path: [String], isOpen: Bool) {
        self.path = path
        self.isOpen = isOpen
        let title = path.last ?? String(localized: "All Stickers")
        var attributes = AttributeContainer()
        attributes.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold), maximumPointSize: 22, compatibleWith: traitCollection)
        configuration?.attributedTitle = AttributedString(title, attributes: attributes)
        configuration?.image = UIImage(systemName: isOpen ? "chevron.up" : "chevron.down",
                                       withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small))
        largeContentTitle = title
        accessibilityLabel = String(localized: "Folder")
        accessibilityValue = path.isEmpty ? title : path.reversed().joined(separator: String(localized: ", in "))
        accessibilityHint = isOpen ? String(localized: "Closes the folder list") : String(localized: "Shows the folder list")
    }
}
