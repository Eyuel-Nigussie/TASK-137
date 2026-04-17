import XCTest
@testable import RailCommerce

final class MembershipServiceTests: XCTestCase {

    private let admin = User(id: "admin", displayName: "Admin", role: .administrator)
    private let customer = User(id: "u1", displayName: "Customer", role: .customer)

    func testEnrollAndRetrieve() throws {
        let svc = MembershipService()
        let m = try svc.enroll(userId: "u1", actingUser: customer)
        XCTAssertEqual(m.tier, .bronze)
        XCTAssertEqual(m.pointsBalance, 0)
        XCTAssertEqual(svc.member("u1"), m)
    }

    func testDuplicateEnrollThrows() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        XCTAssertThrowsError(try svc.enroll(userId: "u1", actingUser: customer)) { err in
            XCTAssertEqual(err as? MembershipError, .alreadyEnrolled)
        }
    }

    func testAccrueAndRedeemPoints() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        try svc.accruePoints(userId: "u1", points: 100, actingUser: admin)
        XCTAssertEqual(svc.member("u1")?.pointsBalance, 100)
        try svc.redeemPoints(userId: "u1", points: 40, actingUser: customer)
        XCTAssertEqual(svc.member("u1")?.pointsBalance, 60)
    }

    func testRedeemInsufficientThrows() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        XCTAssertThrowsError(try svc.redeemPoints(userId: "u1", points: 1, actingUser: customer)) { err in
            XCTAssertEqual(err as? MembershipError, .insufficientPoints)
        }
    }

    func testUpgradeTier() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        try svc.upgradeTier(userId: "u1", to: .gold, actingUser: admin)
        XCTAssertEqual(svc.member("u1")?.tier, .gold)
    }

    func testTagMember() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        try svc.tagMember(userId: "u1", tag: "vip", actingUser: admin)
        XCTAssertTrue(svc.member("u1")?.tags.contains("vip") ?? false)
    }

    func testCampaignCreateAndList() throws {
        let svc = MembershipService()
        let c = MarketingCampaign(id: "c1", name: "Summer", offerDescription: "10% off")
        _ = try svc.createCampaign(c, actingUser: admin)
        XCTAssertEqual(svc.allCampaigns().count, 1)
        XCTAssertEqual(svc.campaign("c1"), c)
    }

    func testDeactivateCampaign() throws {
        let svc = MembershipService()
        _ = try svc.createCampaign(MarketingCampaign(id: "c1", name: "X", offerDescription: "Y"), actingUser: admin)
        try svc.deactivateCampaign("c1", actingUser: admin)
        XCTAssertFalse(svc.campaign("c1")!.active)
    }

    func testDeactivateMissingThrows() {
        let svc = MembershipService()
        XCTAssertThrowsError(try svc.deactivateCampaign("ghost", actingUser: admin)) { err in
            XCTAssertEqual(err as? MembershipError, .campaignNotFound)
        }
    }

    func testEligibleCampaignsFiltersByTierAndTags() throws {
        let svc = MembershipService()
        let goldUser = User(id: "u1", displayName: "U", role: .customer)
        _ = try svc.enroll(userId: "u1", tier: .gold, actingUser: goldUser)
        try svc.tagMember(userId: "u1", tag: "frequent", actingUser: admin)
        _ = try svc.createCampaign(MarketingCampaign(id: "c1", name: "Gold+",
                                              targetTiers: [.gold, .platinum],
                                              offerDescription: "VIP lounge"), actingUser: admin)
        _ = try svc.createCampaign(MarketingCampaign(id: "c2", name: "Bronze only",
                                              targetTiers: [.bronze],
                                              offerDescription: "Upgrade offer"), actingUser: admin)
        _ = try svc.createCampaign(MarketingCampaign(id: "c3", name: "Frequent tag",
                                              targetTags: ["frequent"],
                                              offerDescription: "Loyalty bonus"), actingUser: admin)
        let eligible = svc.eligibleCampaigns(for: "u1")
        XCTAssertEqual(eligible.map { $0.id }, ["c1", "c3"])
    }

    func testEligibleCampaignsExcludesInactive() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        _ = try svc.createCampaign(MarketingCampaign(id: "c1", name: "X", offerDescription: "Y"), actingUser: admin)
        try svc.deactivateCampaign("c1", actingUser: admin)
        XCTAssertTrue(svc.eligibleCampaigns(for: "u1").isEmpty)
    }

    func testPersistenceHydration() throws {
        let store = InMemoryPersistenceStore()
        let svc = MembershipService(persistence: store)
        _ = try svc.enroll(userId: "u1", tier: .silver, actingUser: customer)
        _ = try svc.createCampaign(MarketingCampaign(id: "c1", name: "X", offerDescription: "Y"), actingUser: admin)

        let rebuilt = MembershipService(persistence: store)
        XCTAssertEqual(rebuilt.member("u1")?.tier, .silver)
        XCTAssertEqual(rebuilt.campaign("c1")?.name, "X")
    }

    func testNotEnrolledThrows() {
        let svc = MembershipService()
        XCTAssertThrowsError(try svc.accruePoints(userId: "ghost", points: 1, actingUser: admin)) { err in
            XCTAssertEqual(err as? MembershipError, .notEnrolled)
        }
        XCTAssertThrowsError(try svc.redeemPoints(userId: "ghost", points: 1, actingUser: admin))
        XCTAssertThrowsError(try svc.upgradeTier(userId: "ghost", to: .gold, actingUser: admin))
        XCTAssertThrowsError(try svc.tagMember(userId: "ghost", tag: "x", actingUser: admin))
    }

    func testAllMembersSortedByUserId() throws {
        let svc = MembershipService()
        let userB = User(id: "b", displayName: "B", role: .customer)
        let userA = User(id: "a", displayName: "A", role: .customer)
        _ = try svc.enroll(userId: "b", actingUser: userB)
        _ = try svc.enroll(userId: "a", actingUser: userA)
        XCTAssertEqual(svc.allMembers().map { $0.userId }, ["a", "b"])
    }

    func testMembershipTierCodable() throws {
        for t in MembershipTier.allCases {
            let data = try JSONEncoder().encode(t)
            XCTAssertEqual(try JSONDecoder().decode(MembershipTier.self, from: data), t)
        }
    }

    // MARK: - Authorization boundary tests

    func testCustomerCanSelfEnroll() throws {
        let svc = MembershipService()
        XCTAssertNoThrow(try svc.enroll(userId: "u1", actingUser: customer))
    }

    func testCustomerCannotEnrollOtherUser() {
        let svc = MembershipService()
        XCTAssertThrowsError(try svc.enroll(userId: "other", actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testAdminCanEnrollOtherUser() throws {
        let svc = MembershipService()
        XCTAssertNoThrow(try svc.enroll(userId: "someone", actingUser: admin))
    }

    func testCustomerCannotAccruePoints() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        XCTAssertThrowsError(try svc.accruePoints(userId: "u1", points: 100, actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testCustomerCanSelfRedeem() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        try svc.accruePoints(userId: "u1", points: 100, actingUser: admin)
        XCTAssertNoThrow(try svc.redeemPoints(userId: "u1", points: 50, actingUser: customer))
    }

    func testCustomerCannotRedeemForOther() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "other", actingUser: admin)
        try svc.accruePoints(userId: "other", points: 100, actingUser: admin)
        XCTAssertThrowsError(try svc.redeemPoints(userId: "other", points: 50, actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testCustomerCannotUpgradeTier() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        XCTAssertThrowsError(try svc.upgradeTier(userId: "u1", to: .gold, actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testCustomerCannotTagMember() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        XCTAssertThrowsError(try svc.tagMember(userId: "u1", tag: "vip", actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testCustomerCannotCreateCampaign() {
        let svc = MembershipService()
        let c = MarketingCampaign(id: "c1", name: "X", offerDescription: "Y")
        XCTAssertThrowsError(try svc.createCampaign(c, actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testCustomerCannotDeactivateCampaign() throws {
        let svc = MembershipService()
        _ = try svc.createCampaign(MarketingCampaign(id: "c1", name: "X", offerDescription: "Y"), actingUser: admin)
        XCTAssertThrowsError(try svc.deactivateCampaign("c1", actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }
}
