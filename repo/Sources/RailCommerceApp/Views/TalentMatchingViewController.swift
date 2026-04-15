#if canImport(UIKit)
import UIKit
import RailCommerce

/// Offline talent matching and resume browsing for administrators and CSRs.
final class TalentMatchingViewController: UITableViewController {

    private let app: RailCommerce
    private let user: User
    private var matches: [TalentMatch] = []
    private var searchBar: UISearchBar!

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Talent"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "match")
        setupSearchBar()
        runSearch(skill: "swift")
    }

    private func setupSearchBar() {
        searchBar = UISearchBar()
        searchBar.placeholder = "Search by skill…"
        searchBar.delegate = self
        tableView.tableHeaderView = searchBar
    }

    private func runSearch(skill: String) {
        let criteria = TalentSearchCriteria(
            wantedSkills: skill.isEmpty ? [] : [skill.lowercased()]
        )
        do {
            matches = try app.talent.search(criteria, by: user)
        } catch {
            matches = []
            let alert = UIAlertController(title: "Permission Denied",
                                          message: error.localizedDescription,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
        tableView.reloadData()
    }

    // MARK: - UITableViewDataSource

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        matches.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "match", for: indexPath)
        let match = matches[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = match.resumeId
        config.secondaryText = "Score: \(String(format: "%.0f%%", match.score * 100)) — \(match.explanation)"
        cell.contentConfiguration = config
        return cell
    }
}

// MARK: - UISearchBarDelegate

extension TalentMatchingViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        runSearch(skill: searchBar.text ?? "")
    }
}
#endif
