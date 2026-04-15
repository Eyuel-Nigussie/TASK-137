#if canImport(UIKit)
import UIKit
import RailCommerce

/// Browse the SKU catalog filtered by taxonomy (region / theme / rider type).
final class BrowseViewController: UITableViewController {

    private let app: RailCommerce
    private let user: User
    private var skus: [SKU] = []

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Browse"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            style: .plain, target: self, action: #selector(filterTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "sku")
        reload(tag: TaxonomyTag())
    }

    private func reload(tag: TaxonomyTag) {
        skus = app.catalog.filter(tag)
        tableView.reloadData()
    }

    @objc private func filterTapped() {
        let sheet = UIAlertController(title: "Filter Region", message: nil, preferredStyle: .actionSheet)
        for region in Region.allCases {
            sheet.addAction(UIAlertAction(title: region.rawValue.capitalized, style: .default) { [weak self] _ in
                self?.reload(tag: TaxonomyTag(region: region))
            })
        }
        sheet.addAction(UIAlertAction(title: "All", style: .default) { [weak self] _ in
            self?.reload(tag: TaxonomyTag())
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
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
            let cart = Cart(catalog: self.app.catalog)
            try? cart.add(skuId: sku.id, quantity: 1)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
#endif
