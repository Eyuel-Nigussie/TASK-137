#if canImport(UIKit)
import UIKit
import RailCommerce

/// Customer-facing published content browser (travel advisories, onboard offers)
/// with full COMBINED taxonomy filtering (region × theme × rider type). Each
/// facet accumulates — selecting a region preserves any previously-chosen
/// theme and rider type, mirroring the SKU `BrowseViewController`.
final class ContentBrowseViewController: UITableViewController {

    private let app: RailCommerce
    private let user: User
    private var items: [ContentItem] = []
    private var currentFilter = TaxonomyTag()
    private let emptyLabel = UILabel()

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateTitle()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            style: .plain, target: self, action: #selector(filterTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Filter content"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "content")
        setupEmptyState()
        reload()
    }

    private func setupEmptyState() {
        emptyLabel.text = "No published content matches the current filter."
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.numberOfLines = 0
        tableView.backgroundView = emptyLabel
    }

    private func reload() {
        items = app.publishing.items(filter: currentFilter, publishedOnly: true)
        emptyLabel.isHidden = !items.isEmpty
        tableView.reloadData()
        updateTitle()
    }

    /// Shows active facets as a breadcrumb in the navigation title so the
    /// user can see the combined filter at a glance.
    private func updateTitle() {
        var parts: [String] = []
        if let r = currentFilter.region { parts.append(r.rawValue.capitalized) }
        if let t = currentFilter.theme { parts.append(t.rawValue.capitalized) }
        if let r = currentFilter.riderType { parts.append(r.rawValue.capitalized) }
        title = parts.isEmpty
            ? "Advisories & Offers"
            : "Advisories — " + parts.joined(separator: " · ")
    }

    // MARK: - Combined taxonomy filter

    @objc private func filterTapped() {
        let sheet = UIAlertController(title: "Filter", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Region…", style: .default) { [weak self] _ in
            self?.presentRegionPicker()
        })
        sheet.addAction(UIAlertAction(title: "Theme…", style: .default) { [weak self] _ in
            self?.presentThemePicker()
        })
        sheet.addAction(UIAlertAction(title: "Rider Type…", style: .default) { [weak self] _ in
            self?.presentRiderPicker()
        })
        sheet.addAction(UIAlertAction(title: "Clear All Filters", style: .destructive) { [weak self] _ in
            self?.currentFilter = TaxonomyTag()
            self?.reload()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func presentRegionPicker() {
        let sheet = UIAlertController(title: "Region", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Any", style: .default) { [weak self] _ in
            self?.setRegion(nil)
        })
        for region in Region.allCases {
            sheet.addAction(UIAlertAction(title: region.rawValue.capitalized, style: .default) { [weak self] _ in
                self?.setRegion(region)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func presentThemePicker() {
        let sheet = UIAlertController(title: "Theme", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Any", style: .default) { [weak self] _ in
            self?.setTheme(nil)
        })
        for theme in Theme.allCases {
            sheet.addAction(UIAlertAction(title: theme.rawValue.capitalized, style: .default) { [weak self] _ in
                self?.setTheme(theme)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func presentRiderPicker() {
        let sheet = UIAlertController(title: "Rider Type", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Any", style: .default) { [weak self] _ in
            self?.setRider(nil)
        })
        for rider in RiderType.allCases {
            sheet.addAction(UIAlertAction(title: rider.rawValue.capitalized, style: .default) { [weak self] _ in
                self?.setRider(rider)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    // TaxonomyTag fields are immutable `let`s so each facet update rebuilds
    // the tag while preserving the other two facets.
    private func setRegion(_ region: Region?) {
        currentFilter = TaxonomyTag(region: region,
                                    theme: currentFilter.theme,
                                    riderType: currentFilter.riderType)
        reload()
    }
    private func setTheme(_ theme: Theme?) {
        currentFilter = TaxonomyTag(region: currentFilter.region,
                                    theme: theme,
                                    riderType: currentFilter.riderType)
        reload()
    }
    private func setRider(_ rider: RiderType?) {
        currentFilter = TaxonomyTag(region: currentFilter.region,
                                    theme: currentFilter.theme,
                                    riderType: rider)
        reload()
    }

    // MARK: - UITableViewDataSource

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "content", for: indexPath)
        let item = items[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = item.title
        config.secondaryText = "\(item.kind.rawValue.capitalized) — \(item.tag.region?.rawValue.capitalized ?? "All regions")"
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items[indexPath.row]
        let body = item.versions.last?.body ?? "(no content)"
        let alert = UIAlertController(title: item.title, message: body,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
