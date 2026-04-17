import Foundation

public struct Resume: Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var skills: Set<String>
    public var yearsExperience: Int
    public var certifications: Set<String>
    public var tags: Set<String>

    public init(id: String, name: String, skills: Set<String>, yearsExperience: Int,
                certifications: Set<String>, tags: Set<String> = []) {
        self.id = id; self.name = name; self.skills = skills
        self.yearsExperience = yearsExperience
        self.certifications = certifications; self.tags = tags
    }
}

public indirect enum BooleanFilter: Equatable, Sendable {
    case hasSkill(String)
    case hasCertification(String)
    case minYears(Int)
    case hasTag(String)
    case and(BooleanFilter, BooleanFilter)
    case or(BooleanFilter, BooleanFilter)
    case not(BooleanFilter)

    public func evaluate(_ r: Resume) -> Bool {
        switch self {
        case .hasSkill(let s): return r.skills.contains(s)
        case .hasCertification(let c): return r.certifications.contains(c)
        case .minYears(let y): return r.yearsExperience >= y
        case .hasTag(let t): return r.tags.contains(t)
        case .and(let a, let b): return a.evaluate(r) && b.evaluate(r)
        case .or(let a, let b): return a.evaluate(r) || b.evaluate(r)
        case .not(let x): return !x.evaluate(r)
        }
    }
}

public struct TalentMatch: Equatable, Sendable {
    public let resumeId: String
    public let score: Double
    public let skillScore: Double
    public let experienceScore: Double
    public let certScore: Double
    public let matchedSkills: [String]
    public let matchedCertifications: [String]
    public let explanation: String
}

public struct TalentSearchCriteria: Equatable, Sendable {
    public let wantedSkills: Set<String>
    public let wantedCertifications: Set<String>
    public let desiredYears: Int
    public let filter: BooleanFilter?

    public init(wantedSkills: Set<String> = [], wantedCertifications: Set<String> = [],
                desiredYears: Int = 0, filter: BooleanFilter? = nil) {
        self.wantedSkills = wantedSkills
        self.wantedCertifications = wantedCertifications
        self.desiredYears = desiredYears
        self.filter = filter
    }
}

public struct SavedSearch: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let wantedSkills: [String]
    public let wantedCertifications: [String]
    public let desiredYears: Int
}

public enum TalentError: Error, Equatable {
    case persistenceFailed
}

public final class TalentMatchingService {
    public static let skillWeight = 0.5
    public static let experienceWeight = 0.3
    public static let certificationWeight = 0.2
    public static let resumePrefix = "talent.resume."
    public static let savedSearchPrefix = "talent.saved."

    private let persistence: PersistenceStore?
    private let logger: Logger
    private var resumes: [String: Resume] = [:]
    private var skillIndex: [String: Set<String>] = [:]
    private var certIndex: [String: Set<String>] = [:]
    private var tagIndex: [String: Set<String>] = [:]
    private var savedSearches: [String: SavedSearch] = [:]

    public init(persistence: PersistenceStore? = nil, logger: Logger = SilentLogger()) {
        self.persistence = persistence
        self.logger = logger
        hydrate()
    }

    /// Imports a resume. Non-throwing for bulk/tooling ergonomics, but rolls
    /// back the in-memory index on durability failure and logs the incident
    /// so the next import retry is not silently lost.
    public func importResume(_ r: Resume) {
        let prior = resumes[r.id]
        resumes[r.id] = r
        for s in r.skills { skillIndex[s, default: []].insert(r.id) }
        for c in r.certifications { certIndex[c, default: []].insert(r.id) }
        for t in r.tags { tagIndex[t, default: []].insert(r.id) }
        do {
            try persistResume(r)
        } catch {
            // Rebuild indices around the prior record (or drop them entirely
            // if this was a first-time import that never durably persisted).
            resumes[r.id] = prior
            rebuildIndicesAfterRollback(id: r.id, restored: prior)
            logger.error(.content, "importResume persist failed id=\(r.id) err=\(error)")
            return
        }
        logger.info(.content, "importResume id=\(r.id)")
    }

    public func allResumes() -> [Resume] { resumes.values.sorted { $0.id < $1.id } }

    public func bulkTag(ids: [String], add tag: String) {
        for id in ids {
            guard var r = resumes[id] else { continue }
            let prior = resumes[id]
            let hadTag = r.tags.contains(tag)
            r.tags.insert(tag)
            resumes[id] = r
            tagIndex[tag, default: []].insert(id)
            do {
                try persistResume(r)
            } catch {
                resumes[id] = prior
                if !hadTag { tagIndex[tag]?.remove(id) }
                logger.error(.content, "bulkTag persist failed id=\(id) err=\(error)")
            }
        }
    }

    public func saveSearch(_ s: SavedSearch) {
        let prior = savedSearches[s.id]
        savedSearches[s.id] = s
        do {
            try persistSavedSearch(s)
        } catch {
            if let prior { savedSearches[s.id] = prior }
            else { savedSearches.removeValue(forKey: s.id) }
            logger.error(.content, "saveSearch persist failed id=\(s.id) err=\(error)")
        }
    }

    /// Rebuilds skill/cert/tag indices so they reflect only the resumes
    /// currently in the in-memory store. Used after a persistence rollback
    /// evicts a new-import entry that never made it to disk.
    private func rebuildIndicesAfterRollback(id: String, restored: Resume?) {
        skillIndex = skillIndex.mapValues { $0.filter { $0 != id } }
        certIndex = certIndex.mapValues { $0.filter { $0 != id } }
        tagIndex = tagIndex.mapValues { $0.filter { $0 != id } }
        if let r = restored {
            for s in r.skills { skillIndex[s, default: []].insert(r.id) }
            for c in r.certifications { certIndex[c, default: []].insert(r.id) }
            for t in r.tags { tagIndex[t, default: []].insert(r.id) }
        }
    }
    public func savedSearch(_ id: String) -> SavedSearch? { savedSearches[id] }
    public func listSavedSearches() -> [SavedSearch] {
        savedSearches.values.sorted { $0.id < $1.id }
    }

    /// Role-enforced search: requires the caller to hold `.matchTalent`.
    /// This is the only public search entry point; callers must pass an authenticated
    /// `User` whose role grants `.matchTalent`.
    public func search(_ criteria: TalentSearchCriteria, by user: User) throws -> [TalentMatch] {
        try RolePolicy.enforce(user: user, .matchTalent)
        return searchUnchecked(criteria)
    }

    /// Unchecked search for internal use only (tests and guarded callers).
    /// Intentionally `internal` so external callers cannot bypass role enforcement.
    internal func searchUnchecked(_ criteria: TalentSearchCriteria) -> [TalentMatch] {
        var candidates: [Resume] = Array(resumes.values)
        if let f = criteria.filter {
            candidates = candidates.filter { f.evaluate($0) }
        }
        let matches = candidates.map { r -> TalentMatch in
            score(r, criteria: criteria)
        }
        return matches
            .filter { $0.score > 0 || (criteria.wantedSkills.isEmpty
                                     && criteria.wantedCertifications.isEmpty
                                     && criteria.desiredYears == 0) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.resumeId < b.resumeId
            }
    }

    private func score(_ r: Resume, criteria: TalentSearchCriteria) -> TalentMatch {
        let matchedSkills = criteria.wantedSkills.intersection(r.skills).sorted()
        let skillRatio: Double = criteria.wantedSkills.isEmpty
            ? 0
            : Double(matchedSkills.count) / Double(criteria.wantedSkills.count)

        let matchedCerts = criteria.wantedCertifications.intersection(r.certifications).sorted()
        let certRatio: Double = criteria.wantedCertifications.isEmpty
            ? 0
            : Double(matchedCerts.count) / Double(criteria.wantedCertifications.count)

        let expRatio: Double
        if criteria.desiredYears <= 0 {
            expRatio = 0
        } else {
            expRatio = min(1.0, Double(r.yearsExperience) / Double(criteria.desiredYears))
        }

        let skillScore = skillRatio * Self.skillWeight
        let expScore = expRatio * Self.experienceWeight
        let certScore = certRatio * Self.certificationWeight
        let total = skillScore + expScore + certScore

        let explanation = "skills=\(Int(skillRatio * 100))%,"
            + "experience=\(Int(expRatio * 100))%,"
            + "certs=\(Int(certRatio * 100))%"

        return TalentMatch(
            resumeId: r.id, score: total,
            skillScore: skillScore,
            experienceScore: expScore,
            certScore: certScore,
            matchedSkills: matchedSkills,
            matchedCertifications: matchedCerts,
            explanation: explanation
        )
    }

    // MARK: - Persistence

    private func persistResume(_ r: Resume) throws {
        guard let persistence else { return }
        do {
            let data = try JSONEncoder().encode(r)
            try persistence.save(key: Self.resumePrefix + r.id, data: data)
        } catch {
            logger.error(.persistence, "talent persist resume failed id=\(r.id)")
            throw TalentError.persistenceFailed
        }
    }

    private func persistSavedSearch(_ s: SavedSearch) throws {
        guard let persistence else { return }
        do {
            let data = try JSONEncoder().encode(s)
            try persistence.save(key: Self.savedSearchPrefix + s.id, data: data)
        } catch {
            logger.error(.persistence, "talent persist search failed id=\(s.id)")
            throw TalentError.persistenceFailed
        }
    }

    private func hydrate() {
        guard let persistence else { return }
        let decoder = JSONDecoder()
        do {
            for entry in try persistence.loadAll(prefix: Self.resumePrefix) {
                if let r = try? decoder.decode(Resume.self, from: entry.data) {
                    resumes[r.id] = r
                    for s in r.skills { skillIndex[s, default: []].insert(r.id) }
                    for c in r.certifications { certIndex[c, default: []].insert(r.id) }
                    for t in r.tags { tagIndex[t, default: []].insert(r.id) }
                }
            }
            for entry in try persistence.loadAll(prefix: Self.savedSearchPrefix) {
                if let s = try? decoder.decode(SavedSearch.self, from: entry.data) {
                    savedSearches[s.id] = s
                }
            }
        } catch {
            logger.error(.persistence, "talent hydrate failed err=\(error)")
        }
    }
}
