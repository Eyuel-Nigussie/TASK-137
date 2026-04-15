import XCTest
@testable import RailCommerce

final class ContentPublishingServiceTests: XCTestCase {
    private func setup(battery: FakeBattery = FakeBattery()) -> (ContentPublishingService, FakeClock, FakeBattery) {
        let clock = FakeClock()
        return (ContentPublishingService(clock: clock, battery: battery), clock, battery)
    }

    private let reviewer = User(id: "rev", displayName: "R", role: .contentReviewer)
    private let editor = User(id: "ed", displayName: "E", role: .contentEditor)

    func testCreateDraft() {
        let (svc, _, _) = setup()
        let item = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "Snow Alert",
                                   tag: TaxonomyTag(region: .northeast), body: "v1", editorId: editor.id)
        XCTAssertEqual(item.status, .draft)
        XCTAssertEqual(item.versions.count, 1)
    }

    func testEditAndReviewPublish() throws {
        let (svc, _, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v1", editorId: editor.id)
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        try svc.approve(id: "c1", reviewer: reviewer)
        XCTAssertEqual(svc.get("c1")?.status, .published)
    }

    func testEditOnlyAllowedForDraftOrRejected() throws {
        let (svc, _, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v1", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        XCTAssertThrowsError(try svc.edit(id: "c1", body: "v2", editorId: editor.id)) { err in
            XCTAssertEqual(err as? ContentError, .invalidState)
        }
        try svc.reject(id: "c1", reviewer: reviewer)
        XCTAssertNoThrow(try svc.edit(id: "c1", body: "v3", editorId: editor.id))
    }

    func testEditNotFound() {
        let (svc, _, _) = setup()
        XCTAssertThrowsError(try svc.edit(id: "missing", body: "x", editorId: editor.id)) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
    }

    func testVersionCapAtTen() throws {
        let (svc, _, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v1", editorId: editor.id)
        for i in 2...15 {
            _ = try svc.edit(id: "c1", body: "v\(i)", editorId: editor.id)
        }
        let item = svc.get("c1")!
        XCTAssertEqual(item.versions.count, ContentPublishingService.maxVersions)
        XCTAssertEqual(item.currentVersion, 15)
    }

    func testSubmitForReviewInvalidState() throws {
        let (svc, _, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v1", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        XCTAssertThrowsError(try svc.submitForReview(id: "c1")) { err in
            XCTAssertEqual(err as? ContentError, .invalidState)
        }
    }

    func testSubmitNotFound() {
        let (svc, _, _) = setup()
        XCTAssertThrowsError(try svc.submitForReview(id: "nope")) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
    }

    func testApproveRequiresReviewer() throws {
        let (svc, _, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        XCTAssertThrowsError(try svc.approve(id: "c1", reviewer: editor)) { err in
            XCTAssertEqual(err as? ContentError, .notReviewer)
        }
        XCTAssertThrowsError(try svc.approve(id: "missing", reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
    }

    func testApproveOnlyFromReview() throws {
        let (svc, _, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v", editorId: editor.id)
        XCTAssertThrowsError(try svc.approve(id: "c1", reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .invalidState)
        }
    }

    func testRejectRequiresReviewer() throws {
        let (svc, _, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        XCTAssertThrowsError(try svc.reject(id: "c1", reviewer: editor)) { err in
            XCTAssertEqual(err as? ContentError, .notReviewer)
        }
        XCTAssertThrowsError(try svc.reject(id: "missing", reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
        // state invalid
        _ = svc.createDraft(id: "c2", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v", editorId: editor.id)
        XCTAssertThrowsError(try svc.reject(id: "c2", reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .invalidState)
        }
    }

    func testScheduleAndProcess() throws {
        let (svc, clock, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(3600), reviewer: reviewer)
        XCTAssertEqual(svc.get("c1")?.status, .scheduled)
        XCTAssertTrue(svc.processScheduled().isEmpty)
        clock.advance(by: 3700)
        XCTAssertEqual(svc.processScheduled(), ["c1"])
        XCTAssertEqual(svc.get("c1")?.status, .published)
    }

    func testScheduleInPastRejected() throws {
        let (svc, clock, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        XCTAssertThrowsError(try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(-10),
                                              reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .scheduleInPast)
        }
    }

    func testScheduleRequiresReviewerAndPresence() throws {
        let (svc, clock, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        XCTAssertThrowsError(try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(10), reviewer: editor)) { err in
            XCTAssertEqual(err as? ContentError, .notReviewer)
        }
        XCTAssertThrowsError(try svc.schedule(id: "missing", at: clock.now().addingTimeInterval(10), reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
        // wrong state
        _ = svc.createDraft(id: "c2", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v", editorId: editor.id)
        XCTAssertThrowsError(try svc.schedule(id: "c2", at: clock.now().addingTimeInterval(10), reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .invalidState)
        }
    }

    func testLowBatteryDefersProcessing() throws {
        let battery = FakeBattery(level: 0.1, isLowPowerMode: false)
        let (svc, clock, _) = setup(battery: battery)
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(60), reviewer: reviewer)
        clock.advance(by: 120)
        XCTAssertTrue(svc.processScheduled().isEmpty)
        XCTAssertEqual(svc.deferredProcessing, ["c1"])
    }

    func testLowPowerModeDefersProcessing() throws {
        let battery = FakeBattery(level: 1.0, isLowPowerMode: true)
        let (svc, clock, _) = setup(battery: battery)
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(60), reviewer: reviewer)
        clock.advance(by: 120)
        XCTAssertTrue(svc.processScheduled().isEmpty)
    }

    func testRollback() throws {
        let (svc, _, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v1", editorId: editor.id)
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id)
        try svc.rollback(id: "c1")
        let item = svc.get("c1")!
        XCTAssertEqual(item.currentVersion, 1)
        XCTAssertEqual(item.status, .rolledBack)
    }

    func testRollbackWithoutPriorVersion() {
        let (svc, _, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(), body: "v1", editorId: editor.id)
        XCTAssertThrowsError(try svc.rollback(id: "c1")) { err in
            XCTAssertEqual(err as? ContentError, .noPriorVersion)
        }
    }

    func testRollbackNotFound() {
        let (svc, _, _) = setup()
        XCTAssertThrowsError(try svc.rollback(id: "x")) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
    }

    func testItemsListFilterAndPublishedOnly() throws {
        let (svc, _, _) = setup()
        _ = svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                            tag: TaxonomyTag(region: .northeast), body: "v", editorId: editor.id)
        try svc.submitForReview(id: "c1")
        try svc.approve(id: "c1", reviewer: reviewer)
        _ = svc.createDraft(id: "c2", kind: .travelAdvisory, title: "y",
                            tag: TaxonomyTag(region: .west), body: "v", editorId: editor.id)
        XCTAssertEqual(svc.items().map { $0.id }, ["c1"])
        XCTAssertEqual(svc.items(publishedOnly: false).count, 2)
        XCTAssertEqual(svc.items(filter: TaxonomyTag(region: .northeast)).map { $0.id }, ["c1"])
    }

    func testContentKindAndStatusCodable() throws {
        for k in [ContentKind.travelAdvisory, .onboardOffer] {
            let data = try JSONEncoder().encode(k)
            XCTAssertEqual(try JSONDecoder().decode(ContentKind.self, from: data), k)
        }
        for s in [ContentStatus.draft, .inReview, .published, .rejected, .scheduled, .rolledBack] {
            let data = try JSONEncoder().encode(s)
            XCTAssertEqual(try JSONDecoder().decode(ContentStatus.self, from: data), s)
        }
    }
}
