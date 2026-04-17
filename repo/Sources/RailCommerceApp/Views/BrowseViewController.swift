#if canImport(UIKit)
import UIKit
import RailCommerce

/// Browse the SKU catalog filtered by a combined `TaxonomyTag`
/// (region × theme × rider type). Each facet accumulates — selecting a region
/// preserves any previously-chosen theme / rider type, and "Clear" resets all
/// facets at once. This satisfies the prompt's "configurable taxonomy" browsing.
final class BrowseViewController: UITableViewController {

    private let app: RailCommerce
    private let user: User
    private var skus: [SKU] = []

    /// Current accumulated filter. Each facet is optional — nil means "any".
    private var currentFilter = TaxonomyTag()

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    private let emptyLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Browse"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            style: .plain, target: self, action: #selector(filterTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Filter catalog"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "sku")
        emptyLabel.text = "No items match the current filter."
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.numberOfLines = 0
        tableView.backgroundView = emptyLabel
        reload()
    }

    private func reload() {
        skus = app.catalog.filter(currentFilter)
        emptyLabel.isHidden = !skus.isEmpty
        tableView.reloadData()
        updateTitle()
    }

    /// Shows a concise "Region / Theme / Rider" breadcrumb in the nav bar so
    /// the user can see at a glance which facets are currently active.
    private func updateTitle() {
        var parts: [String] = []
        if let r = currentFilter.region { parts.append(r.rawValue.capitalized) }
        if let t = currentFilter.theme { parts.append(t.rawValue.capitalized) }
        if let r = currentFilter.riderType { parts.append(r.rawValue.capitalized) }
        title = parts.isEmpty ? "Browse" : "Browse — " + parts.joined(separator: " · ")
    }

    /// Top-level filter sheet — pick which facet to edit. Subsequent sheets only
    /// modify the selected facet, preserving the others (combined filtering).
    @objc private func filterTapped() {
        let sheet = UIAlertController(title: "Filter",
                                      message: nil,
                                      preferredStyle: .actionSheet)
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

    // `TaxonomyTag` is an immutable value, so each facet update rebuilds the tag
    // while preserving the other two facets. This is what makes combined
    // filtering work.
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

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        skus.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "sku", for: indexPath)
        let sku = skus[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = sku.title
        config.secondaryText = String(format: "$%.2f", Double(sku.priceCents) / 100)
        cell.contentConfiguration = config
        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard RolePolicy.can(user.role, .purchase) else { return }
        let sku = skus[indexPath.row]
        let alert = UIAlertController(title: sku.title,
                                      message: "Add to cart?",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            guard let self else { return }
            try? self.app.cart(forUser: self.user.id).add(skuId: sku.id, quantity: 1)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
#endif
