import Messages
import os
import StickerizeKit
import UIKit

/// iMessage app: a sticker browser over the shared library. Stickers can be tapped to insert or peeled and dragged
/// onto a message bubble. A header picks a folder to show (its stickers and its subfolders') and searches by name,
/// emoji and folder name. The library reloads when the app (or the Share extension) changes it.
///
/// The grid stays Apple's MSStickerBrowserViewController, so tapping, peeling, animation and VoiceOver work the same
/// in Messages, the emoji keyboard's sticker drawer and FaceTime; a folder or search only changes which stickers it
/// gets. Typing needs the expanded drawer (there is no keyboard in the compact one), so searching asks for it first,
/// and says to pull the drawer up if the host doesn't expand it.
final class MessagesViewController: MSMessagesAppViewController, UISearchBarDelegate {
    private let store = StickerStore.makeDefault()
    private var observer: StickerChangeObserver?
    private let browser = StickerBrowserViewController(stickerSize: .regular)
    private var library = StickerLibrary()
    /// The folder shown (nil for all stickers). Not remembered: the drawer always opens on everything.
    private var scope: UUID?
    private var query = ""
    /// The search bar is shown: from the magnifying glass until Cancel.
    private var isSearching = false
    /// Search was just asked for while compact; focus the field when the drawer expands.
    private var focusesSearchWhenExpanded = false

    private let header = UIStackView()
    private let scopeButton = FolderScopeButton()
    private let searchButton = UIButton(type: .system)
    private let searchBar = UISearchBar()
    private let scopeList = FolderScopeList()
    private let emptyState = UIStackView()
    private let emptyMessage = UILabel()
    private let emptyButton = UIButton(type: .system)
    private var laidOutSize = CGSize.zero
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Stickerize", category: "stickers")

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpHeader()
        addChild(browser)
        // With no keyboard up, the guide sits at the bottom edge, not above the home indicator's safe area.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        let content = UIStackView(arrangedSubviews: [header, searchBar, browser.view])
        content.axis = .vertical
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // Above the keyboard while searching, if the host reports one over this view.
            content.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        browser.didMove(toParent: self)

        scopeList.isHidden = true
        scopeList.backgroundColor = .systemBackground
        scopeList.onPick = { [weak self] folder in self?.pick(folder) }
        scopeList.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scopeList)
        NSLayoutConstraint.activate([
            scopeList.topAnchor.constraint(equalTo: header.bottomAnchor),
            scopeList.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scopeList.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scopeList.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        setUpEmptyState()

        observer = store.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        // Messages may reuse this controller: open on all stickers, with no search, every time.
        scope = nil
        endSearch()
        setScopeListHidden(true)
        reload()
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        searchBar.prompt = nil
        if presentationStyle == .expanded, focusesSearchWhenExpanded {
            focusesSearchWhenExpanded = false
            searchBar.becomeFirstResponder()
        } else if presentationStyle == .compact {
            searchBar.resignFirstResponder()
            // Collapsed without typing anything: the search is over.
            if query.isEmpty { endSearch() }
            showStickers()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The drawer opens at compact height and is resized by the user; lay the grid out again for the real size
        // (a sticker browser reloaded before it had a size has been reported to stay empty until the sheet is dragged).
        guard view.bounds.size != laidOutSize, view.bounds.width > 0 else { return }
        laidOutSize = view.bounds.size
        browser.stickerBrowserView.reloadData()
    }

    // MARK: Stickers

    private func reload() {
        // A plain read: the app replaces files atomically, and this extension never writes.
        do {
            library = try store.library()
        } catch {
            log.error("Couldn't read the sticker library: \(error.localizedDescription, privacy: .public)")
            library = StickerLibrary()
        }
        if let scope, library.folder(scope) == nil { self.scope = nil }
        if !scopeList.isHidden { scopeList.show(library, current: scope) }
        showStickers()
    }

    /// Hands the browser the stickers of the folder shown, filtered by the search.
    private func showStickers() {
        let shown = query.isEmpty ? library.stickers(inTree: scope) : library.search(query, in: scope)
        browser.stickers = shown.compactMap { sticker in
            try? MSSticker(contentsOfFileURL: store.fileURL(for: sticker), localizedDescription: sticker.name)
        }
        log.info("Showing \(self.browser.stickers.count) of \(self.library.stickers.count) stickers from \(String(describing: self.store.location), privacy: .public)")
        updateScopeButton()
        header.isHidden = library.isEmpty
        searchButton.isHidden = library.stickers.isEmpty
        searchBar.isHidden = library.isEmpty || !isSearching

        emptyState.isHidden = !browser.stickers.isEmpty
        emptyButton.isHidden = !query.isEmpty
        if store.location == .local {
            emptyMessage.text = String(localized: "Stickerize can't reach its shared library. Reinstall the app, or check that the App Group is set up in the project.")
        } else if !query.isEmpty {
            emptyMessage.text = String(localized: "No stickers match “\(query)”.")
        } else if scope != nil {
            emptyMessage.text = String(localized: "No stickers in this folder yet.")
        } else {
            emptyMessage.text = String(localized: "No stickers yet. Make some from your photos in the Stickerize app.")
        }
    }

    private func pick(_ folder: UUID?) {
        scope = folder
        setScopeListHidden(true)
        showStickers()
        browser.stickerBrowserView.setContentOffset(.zero, animated: false)
    }

    private func setScopeListHidden(_ hidden: Bool) {
        let changed = scopeList.isHidden != hidden
        if !hidden {
            searchBar.resignFirstResponder()
            focusesSearchWhenExpanded = false
            scopeList.show(library, current: scope)
        }
        scopeList.isHidden = hidden
        // VoiceOver would otherwise still reach the stickers under the list.
        for covered in [browser.view, searchBar, emptyState] as [UIView] { covered.accessibilityElementsHidden = !hidden }
        updateScopeButton()
        if changed { UIAccessibility.post(notification: .layoutChanged, argument: hidden ? browser.view : scopeList) }
    }

    private func updateScopeButton() {
        scopeButton.update(path: library.path(to: scope).map(\.name), isOpen: !scopeList.isHidden)
    }

    // MARK: Search

    private func startSearch() {
        setScopeListHidden(true)
        isSearching = true
        searchBar.isHidden = false
        searchBar.setShowsCancelButton(true, animated: false)
        if presentationStyle == .compact {
            expandForSearch()
        } else {
            searchBar.becomeFirstResponder()
        }
    }

    /// No keyboard in the compact drawer (Apple: "the keyboard is not available"): ask for the expanded one and focus
    /// the field when it arrives, whether the host expands it or the user pulls the drawer up. Apple doesn't say whether
    /// every host of the media context expands on request, so if it doesn't, the field says to pull it up.
    private func expandForSearch() {
        focusesSearchWhenExpanded = true
        requestPresentationStyle(.expanded)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, focusesSearchWhenExpanded, presentationStyle == .compact else { return }
            log.info("The host kept the drawer compact")
            // Not focused later by surprise: once the drawer is up, the user taps the field.
            focusesSearchWhenExpanded = false
            // A line above the field, visible whatever is typed in it.
            searchBar.prompt = String(localized: "Pull the drawer up, then tap the field")
            UIAccessibility.post(notification: .announcement, argument: searchBar.prompt)
        }
    }

    func searchBarShouldBeginEditing(_ searchBar: UISearchBar) -> Bool {
        guard presentationStyle == .compact else { return true }
        expandForSearch()
        return false
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        showStickers()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        if query.isEmpty { endSearch() }
        showStickers()
        // Back to the drawer's usual size, with the results, so stickers are within reach.
        requestPresentationStyle(.compact)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        endSearch()
        showStickers()
    }

    private func endSearch() {
        isSearching = false
        searchBar.text = ""
        query = ""
        focusesSearchWhenExpanded = false
        searchBar.prompt = nil
        searchBar.setShowsCancelButton(false, animated: true)
        searchBar.resignFirstResponder()
    }

    // MARK: UI

    private func setUpHeader() {
        scopeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setScopeListHidden(!scopeList.isHidden)
        }, for: .primaryActionTriggered)

        var search = UIButton.Configuration.plain()
        search.image = UIImage(systemName: "magnifyingglass")
        searchButton.configuration = search
        searchButton.accessibilityLabel = String(localized: "Search Stickers")
        searchButton.addAction(UIAction { [weak self] _ in self?.startSearch() }, for: .primaryActionTriggered)

        var add = UIButton.Configuration.plain()
        add.image = UIImage(systemName: "plus")
        let addButton = UIButton(configuration: add, primaryAction: UIAction { [weak self] _ in self?.openApp() })
        addButton.accessibilityLabel = String(localized: "Make a sticker in Stickerize")

        for button in [searchButton, addButton] {
            button.showsLargeContentViewer = true
            button.largeContentTitle = button.accessibilityLabel
            button.addInteraction(UILargeContentViewerInteraction())
            button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scopeButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(scopeButton)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(searchButton)
        header.addArrangedSubview(addButton)
        header.axis = .horizontal
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = String(localized: "Search Stickers")
        searchBar.autocapitalizationType = .none
        searchBar.returnKeyType = .done
        searchBar.isHidden = true
    }

    private func setUpEmptyState() {
        emptyMessage.numberOfLines = 0
        emptyMessage.textAlignment = .center
        emptyMessage.font = .preferredFont(forTextStyle: .body)
        emptyMessage.textColor = .secondaryLabel
        emptyMessage.adjustsFontForContentSizeCategory = true

        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "Open Stickerize")
        configuration.cornerStyle = .capsule
        emptyButton.configuration = configuration
        emptyButton.addAction(UIAction { [weak self] _ in self?.openApp() }, for: .primaryActionTriggered)

        emptyState.axis = .vertical
        emptyState.alignment = .center
        emptyState.spacing = 12
        emptyState.addArrangedSubview(emptyMessage)
        emptyState.addArrangedSubview(emptyButton)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(emptyState, belowSubview: scopeList)
        NSLayoutConstraint.activate([
            emptyState.centerYAnchor.constraint(equalTo: browser.view.centerYAnchor),
            emptyState.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            emptyState.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
    }

    /// Opens the app's photo picker, importing into the folder shown here.
    private func openApp() {
        var components = URLComponents()
        components.scheme = "stickerize"
        components.host = "import"
        if let scope { components.queryItems = [URLQueryItem(name: "folder", value: scope.uuidString)] }
        guard let url = components.url else { return }
        extensionContext?.open(url)
    }
}

/// The sticker grid. MSStickerBrowserViewController makes itself its browser view's data source when its view loads,
/// so a data source assigned from outside is replaced (and one assigned before the view loads is dropped). Checked in
/// the iOS 27.2 simulator. Subclassing and overriding both methods, as Apple documents, is what works.
final class StickerBrowserViewController: MSStickerBrowserViewController {
    var stickers: [MSSticker] = [] {
        didSet { if isViewLoaded { stickerBrowserView.reloadData() } }
    }

    override func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int {
        stickers.count
    }

    override func stickerBrowserView(_ stickerBrowserView: MSStickerBrowserView, stickerAt index: Int) -> MSSticker {
        stickers[index]
    }
}
