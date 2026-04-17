import XCTest
@testable import RailCommerce

final class TalentMatchingServiceTests: XCTestCase {
    private func sampleService() -> TalentMatchingService {
        let svc = TalentMatchingService()
        svc.importResume(Resume(id: "r1", name: "Alice",
                                skills: ["swift", "ios"], yearsExperience: 5,
                                certifications: ["cpr"]))
        svc.importResume(Resume(id: "r2", name: "Bob",
                                skills: ["kotlin"], yearsExperience: 3,
                                certifications: []))
        return svc
    }

    func testSearchSkillMatchScoreAndExplanation() {
        let svc = sampleService()
        let matches = svc.searchUnchecked(TalentSearchCriteria(
            wantedSkills: ["swift", "ios"], wantedCertifications: ["cpr"], desiredYears: 10))
        XCTAssertEqual(matches.first?.resumeId, "r1")
        XCTAssertEqual(matches.first?.matchedSkills, ["ios", "swift"])
        XCTAssertEqual(matches.first?.matchedCertifications, ["cpr"])
        XCTAssertTrue(matches.first?.explanation.contains("skills=100%") ?? false)
    }

    func testWeightsObey50_30_20() throws {
        let svc = TalentMatchingService()
        svc.importResume(Resume(id: "r", name: "X", skills: ["a"],
                                yearsExperience: 10, certifications: ["c"]))
        let matches = svc.searchUnchecked(TalentSearchCriteria(
            wantedSkills: ["a"], wantedCertifications: ["c"], desiredYears: 10))
        let top = try XCTUnwrap(matches.first)
        // skillScore 0.5, expScore 0.3, certScore 0.2 → total 1.0
        XCTAssertEqual(top.score, 1.0, accuracy: 0.0001)
        XCTAssertEqual(top.skillScore, 0.5, accuracy: 0.0001)
        XCTAssertEqual(top.experienceScore, 0.3, accuracy: 0.0001)
        XCTAssertEqual(top.certScore, 0.2, accuracy: 0.0001)
    }

    func testZeroCriteriaReturnsAllWithZeroScore() {
        let svc = sampleService()
        let matches = svc.searchUnchecked(TalentSearchCriteria())
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches.allSatisfy { $0.score == 0 })
    }

    func testBooleanFilterAnd() {
        let svc = sampleService()
        let f: BooleanFilter = .and(.hasSkill("swift"), .minYears(4))
        let matches = svc.searchUnchecked(TalentSearchCriteria(filter: f))
        XCTAssertEqual(matches.map { $0.resumeId }, ["r1"])
    }

    func testBooleanFilterOrNotAndTag() {
        let svc = sampleService()
        svc.bulkTag(ids: ["r2"], add: "Remote")
        let f: BooleanFilter = .or(.hasTag("Remote"), .hasCertification("cpr"))
        let matches = svc.searchUnchecked(TalentSearchCriteria(filter: f))
        XCTAssertEqual(Set(matches.map { $0.resumeId }), ["r1", "r2"])
        let fNot: BooleanFilter = .not(.hasSkill("swift"))
        let matches2 = svc.searchUnchecked(TalentSearchCriteria(filter: fNot))
        XCTAssertEqual(matches2.map { $0.resumeId }, ["r2"])
    }

    func testBulkTagging() {
        let svc = sampleService()
        svc.bulkTag(ids: ["r1", "r2", "missing"], add: "fast-onboard")
        XCTAssertTrue(svc.allResumes().first!.tags.contains("fast-onboard"))
    }

    func testSavedSearches() {
        let svc = sampleService()
        let s1 = SavedSearch(id: "s1", name: "Swift+CPR",
                             wantedSkills: ["swift"], wantedCertifications: ["cpr"], desiredYears: 3)
        let s2 = SavedSearch(id: "s2", name: "Kotlin",
                             wantedSkills: ["kotlin"], wantedCertifications: [], desiredYears: 1)
        svc.saveSearch(s2)
        svc.saveSearch(s1)
        XCTAssertEqual(svc.savedSearch("s1"), s1)
        XCTAssertEqual(svc.listSavedSearches(), [s1, s2])
    }

    func testImportResumeWithTags() {
        let svc = TalentMatchingService()
        svc.importResume(Resume(id: "r", name: "N", skills: [], yearsExperience: 0,
                                certifications: [], tags: ["remote"]))
        let matches = svc.searchUnchecked(TalentSearchCriteria(filter: .hasTag("remote")))
        XCTAssertEqual(matches.first?.resumeId, "r")
    }

    func testTieBreakingByResumeId() {
        let svc = TalentMatchingService()
        svc.importResume(Resume(id: "b", name: "B", skills: ["s"], yearsExperience: 0, certifications: []))
        svc.importResume(Resume(id: "a", name: "A", skills: ["s"], yearsExperience: 0, certifications: []))
        let m = svc.searchUnchecked(TalentSearchCriteria(wantedSkills: ["s"]))
        XCTAssertEqual(m.map { $0.resumeId }, ["a", "b"])
    }

    func testResumeAndSavedSearchCodable() throws {
        let r = Resume(id: "r", name: "n", skills: ["s"], yearsExperience: 1,
                       certifications: ["c"], tags: ["t"])
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(Resume.self, from: data), r)

        let s = SavedSearch(id: "s", name: "n", wantedSkills: ["a"],
                            wantedCertifications: ["b"], desiredYears: 2)
        let sd = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(SavedSearch.self, from: sd), s)
    }

    func testExplanationIncludesPercentagesEvenWhenZero() {
        let svc = TalentMatchingService()
        svc.importResume(Resume(id: "r", name: "n", skills: [], yearsExperience: 0, certifications: []))
        let m = svc.searchUnchecked(TalentSearchCriteria(wantedSkills: ["missing"]))
        XCTAssertTrue(m.isEmpty, "resume with zero score filtered when criteria exists")
    }
}
