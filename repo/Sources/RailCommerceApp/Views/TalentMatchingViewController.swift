#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
import RailCommerce

/// Offline talent matching, resume browsing, and local-file import for administrators.
final class TalentMatchingViewController: UITableViewController,
    UIDocumentPickerDelegate {

    private let app: RailCommerce
    private let user: User
    private var matches: [TalentMatch] = []
    private var searchBar: UISearchBar!
    private let emptyLabel = UILabel()

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Talent"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.badge.plus"),
            style: .plain, target: self, action: #selector(importTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Import resumes from file"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "match")
        setupSearchBar()
        setupEmptyState()
        runSearch(skill: "")
    }

    private func setupSearchBar() {
        searchBar = UISearchBar()
        searchBar.placeholder = "Search by skill..."
        searchBar.delegate = self
        tableView.tableHeaderView = searchBar
    }

    private func setupEmptyState() {
        emptyLabel.text = "No resumes imported yet.\nTap + to import from a local file."
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.numberOfLines = 0
        tableView.backgroundView = emptyLabel
    }

    private func runSearch(skill: String) {
        let criteria = TalentSearchCriteria(
            wantedSkills: skill.isEmpty ? [] : [skill.lowercased()]
        )
        do {
            matches = try app.talent.search(criteria, by: user)
        } catch {
            matches = []
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            let alert = UIAlertController(title: "Permission Denied",
                                          message: "You don't have permission to search talent.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
        emptyLabel.isHidden = !matches.isEmpty && !app.talent.allResumes().isEmpty
        tableView.reloadData()
    }

    // MARK: - Local file import

    @objc private func importTapped() {
        let types = [UTType.json, UTType.commaSeparatedText].compactMap { $0 }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let resumes: [Resume]
            if url.pathExtension.lowercased() == "csv" {
                resumes = try Self.parseCSV(data)
            } else {
                resumes = try JSONDecoder().decode([Resume].self, from: data)
            }
            for r in resumes { app.talent.importResume(r) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            runSearch(skill: searchBar.text ?? "")
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            let alert = UIAlertController(title: "Import Failed",
                                          message: "Could not parse the selected file. Expected JSON array or CSV with headers: id,name,skills,yearsExperience,certifications.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    /// Parses a CSV file with header row: id,name,skills,yearsExperience,certifications
    /// Skills and certifications are semicolon-separated within their column.
    static func parseCSV(_ data: Data) throws -> [Resume] {
        guard let text = String(data: data, encoding: .utf8) else { throw NSError(domain: "csv", code: 1) }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else { return [] }
        // Skip header row.
        return lines.dropFirst().compactMap { line -> Resume? in
            let cols = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 5 else { return nil }
            let id = cols[0]
            let name = cols[1]
            let skills = Set(cols[2].components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            let years = Int(cols[3]) ?? 0
            let certs = Set(cols[4].components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            return Resume(id: id, name: name, skills: skills,
                          yearsExperience: years, certifications: certs)
        }
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
