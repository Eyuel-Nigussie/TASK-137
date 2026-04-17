import XCTest
@testable import RailCommerce

final class ContentPublishingServiceTests: XCTestCase {
    private func setup(battery: FakeBattery = FakeBattery()) -> (ContentPublishingService, FakeClock, FakeBattery) {
        let clock = FakeClock()
        return (ContentPublishingService(clock: clock, battery: battery), clock, battery)
    }

    private let reviewer = User(id: "rev", displayName: "R", role: .contentReviewer)
    private let editor = User(id: "ed", displayName: "E", role: .contentEditor)

    func testCreateDraft() throws {
        let (svc, _, _) = setup()
        let item = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "Snow Alert",
                                       tag: TaxonomyTag(region: .northeast), body: "v1",
                                       editorId: editor.id, actingUser: editor)
        XCTAssertEqual(item.status, .draft)
        XCTAssertEqual(item.versions.count, 1)
    }

    func testEditAndReviewPublish() throws {
        let (svc, _, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v1", editorId: editor.id, actingUser: editor)
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.approve(id: "c1", reviewer: reviewer)
        XCTAssertEqual(svc.get("c1")?.status, .published)
    }

    func testEditOnlyAllowedForDraftOrRejected() throws {
        let (svc, _, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v1", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        XCTAssertThrowsError(try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)) { err in
            XCTAssertEqual(err as? ContentError, .invalidState)
        }
        try svc.reject(id: "c1", reviewer: reviewer)
        XCTAssertNoThrow(try svc.edit(id: "c1", body: "v3", editorId: editor.id, actingUser: editor))
    }

    func testEditNotFound() {
        let (svc, _, _) = setup()
        XCTAssertThrowsError(try svc.edit(id: "missing", body: "x", editorId: editor.id, actingUser: editor)) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
    }

    func testVersionCapAtTen() throws {
        let (svc, _, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v1", editorId: editor.id, actingUser: editor)
        for i in 2...15 {
            _ = try svc.edit(id: "c1", body: "v\(i)", editorId: editor.id, actingUser: editor)
        }
        let item = svc.get("c1")!
        XCTAssertEqual(item.versions.count, ContentPublishingService.maxVersions)
        XCTAssertEqual(item.currentVersion, 15)
    }

    func testSubmitForReviewInvalidState() throws {
        let (svc, _, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v1", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        XCTAssertThrowsError(try svc.submitForReview(id: "c1", actingUser: editor)) { err in
            XCTAssertEqual(err as? ContentError, .invalidState)
        }
    }

    func testSubmitNotFound() {
        let (svc, _, _) = setup()
        XCTAssertThrowsError(try svc.submitForReview(id: "nope", actingUser: editor)) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
    }

    func testApproveRequiresReviewer() throws {
        let (svc, _, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        XCTAssertThrowsError(try svc.approve(id: "c1", reviewer: editor)) { err in
            XCTAssertEqual(err as? AuthorizationError,
                           .forbidden(required: .publishContent))
        }
        XCTAssertThrowsError(try svc.approve(id: "missing", reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
    }

    func testApproveOnlyFromReview() throws {
        let (svc, _, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v", editorId: editor.id, actingUser: editor)
        XCTAssertThrowsError(try svc.approve(id: "c1", reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .invalidState)
        }
    }

    func testRejectRequiresReviewer() throws {
        let (svc, _, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        XCTAssertThrowsError(try svc.reject(id: "c1", reviewer: editor)) { err in
            XCTAssertEqual(err as? AuthorizationError,
                           .forbidden(required: .publishContent))
        }
        XCTAssertThrowsError(try svc.reject(id: "missing", reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
        // state invalid
        _ = try svc.createDraft(id: "c2", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v", editorId: editor.id, actingUser: editor)
        XCTAssertThrowsError(try svc.reject(id: "c2", reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .invalidState)
        }
    }

    func testScheduleAndProcess() throws {
        let (svc, clock, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(3600), reviewer: reviewer)
        XCTAssertEqual(svc.get("c1")?.status, .scheduled)
        XCTAssertTrue(svc.processScheduled().isEmpty)
        clock.advance(by: 3700)
        XCTAssertEqual(svc.processScheduled(), ["c1"])
        XCTAssertEqual(svc.get("c1")?.status, .published)
    }

    func testScheduleInPastRejected() throws {
        let (svc, clock, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        XCTAssertThrowsError(try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(-10),
                                              reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .scheduleInPast)
        }
    }

    func testScheduleRequiresReviewerAndPresence() throws {
        let (svc, clock, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        XCTAssertThrowsError(try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(10), reviewer: editor)) { err in
            XCTAssertEqual(err as? AuthorizationError,
                           .forbidden(required: .publishContent))
        }
        XCTAssertThrowsError(try svc.schedule(id: "missing", at: clock.now().addingTimeInterval(10), reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
        // wrong state
        _ = try svc.createDraft(id: "c2", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v", editorId: editor.id, actingUser: editor)
        XCTAssertThrowsError(try svc.schedule(id: "c2", at: clock.now().addingTimeInterval(10), reviewer: reviewer)) { err in
            XCTAssertEqual(err as? ContentError, .invalidState)
        }
    }

    func testLowBatteryDefersProcessing() throws {
        // Battery is low AND device is not on external power → heavy work must defer.
        // (Low battery alone is not a defer signal when the device is charging —
        // iOS's own BGProcessingTask contract already requires external power.)
        let battery = FakeBattery(level: 0.1, isLowPowerMode: false,
                                  isCharging: false, isUserInactive: true)
        let (svc, clock, _) = setup(battery: battery)
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(60), reviewer: reviewer)
        clock.advance(by: 120)
        XCTAssertTrue(svc.processScheduled().isEmpty)
        XCTAssertEqual(svc.deferredProcessing, ["c1"])
    }

    func testLowPowerModeDefersProcessing() throws {
        let battery = FakeBattery(level: 1.0, isLowPowerMode: true)
        let (svc, clock, _) = setup(battery: battery)
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(60), reviewer: reviewer)
        clock.advance(by: 120)
        XCTAssertTrue(svc.processScheduled().isEmpty)
    }

    func testRollback() throws {
        let (svc, _, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v1", editorId: editor.id, actingUser: editor)
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)
        try svc.rollback(id: "c1", actingUser: editor)
        let item = svc.get("c1")!
        XCTAssertEqual(item.currentVersion, 1)
        XCTAssertEqual(item.status, .rolledBack)
    }

    func testRollbackWithoutPriorVersion() throws {
        let (svc, _, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(), body: "v1", editorId: editor.id, actingUser: editor)
        XCTAssertThrowsError(try svc.rollback(id: "c1", actingUser: editor)) { err in
            XCTAssertEqual(err as? ContentError, .noPriorVersion)
        }
    }

    func testRollbackNotFound() {
        let (svc, _, _) = setup()
        XCTAssertThrowsError(try svc.rollback(id: "x", actingUser: editor)) { err in
            XCTAssertEqual(err as? ContentError, .notFound)
        }
    }

    func testItemsListFilterAndPublishedOnly() throws {
        let (svc, _, _) = setup()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "x",
                                tag: TaxonomyTag(region: .northeast), body: "v",
                                editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.approve(id: "c1", reviewer: reviewer)
        _ = try svc.createDraft(id: "c2", kind: .travelAdvisory, title: "y",
                                tag: TaxonomyTag(region: .west), body: "v",
                                editorId: editor.id, actingUser: editor)
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
