import Foundation

// MARK: - Membership Marketing Domain

public enum MembershipTier: String, Codable, Sendable, CaseIterable {
    case bronze, silver, gold, platinum
}

public struct Member: Codable, Equatable, Sendable {
    public let userId: String
    public var tier: MembershipTier
    public var pointsBalance: Int
    public var enrolledAt: Date
    public var tags: Set<String>

    public init(userId: String, tier: MembershipTier = .bronze,
                pointsBalance: Int = 0, enrolledAt: Date = Date(),
                tags: Set<String> = []) {
        self.userId = userId; self.tier = tier
        self.pointsBalance = pointsBalance; self.enrolledAt = enrolledAt
        self.tags = tags
    }
}

public struct MarketingCampaign: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let targetTiers: Set<MembershipTier>
    public let targetTags: Set<String>
    public let offerDescription: String
    public var active: Bool

    public init(id: String, name: String, targetTiers: Set<MembershipTier> = Set(MembershipTier.allCases),
                targetTags: Set<String> = [], offerDescription: String, active: Bool = true) {
        self.id = id; self.name = name; self.targetTiers = targetTiers
        self.targetTags = targetTags; self.offerDescription = offerDescription
        self.active = active
    }
}

public enum MembershipError: Error, Equatable {
    case alreadyEnrolled
    case notEnrolled
    case insufficientPoints
    case campaignNotFound
    case unauthorized
    case invalidPoints
}

/// Offline membership marketing engine. Manages member enrollment, tier progression,
/// point accrual/redemption, and targeted campaign delivery.
public final class MembershipService {
    public static let persistencePrefix = "membership."
    public static let campaignPrefix = "campaign."

    private let clock: any Clock
    private let persistence: PersistenceStore?
    private let logger: Logger
    private var members: [String: Member] = [:]
    private var campaigns: [String: MarketingCampaign] = [:]

    public init(clock: any Clock = SystemClock(),
                persistence: PersistenceStore? = nil,
                logger: Logger = SilentLogger()) {
        self.clock = clock
        self.persistence = persistence
        self.logger = logger
        hydrate()
    }

    // MARK: - Member lifecycle

    /// Enrolls a user as a member. Self-enrollment is permitted (actingUser.id == userId);
    /// otherwise the caller must hold `.manageMembership`.
    @discardableResult
    public func enroll(userId: String, tier: MembershipTier = .bronze, actingUser: User) throws -> Member {
        if actingUser.id != userId {
            try RolePolicy.enforce(user: actingUser, .manageMembership)
        }
        guard members[userId] == nil else { throw MembershipError.alreadyEnrolled }
        let member = Member(userId: userId, tier: tier, pointsBalance: 0,
                            enrolledAt: clock.now())
        members[userId] = member
        do {
            try persistMember(member)
        } catch {
            // Roll back the in-memory enrollment so the next attempt retries
            // rather than reporting a member that restart would not show.
            members.removeValue(forKey: userId)
            logger.error(.lifecycle, "membership enroll persist failed userId=\(userId)")
            throw error
        }
        logger.info(.lifecycle, "membership enroll userId=\(userId) tier=\(tier.rawValue)")
        return member
    }

    public func member(_ userId: String) -> Member? { members[userId] }

    public func allMembers() -> [Member] {
        members.values.sorted { $0.userId < $1.userId }
    }

    /// Accrues points for a member. Requires `.manageMembership`.
    /// Rejects non-positive values: negative values would silently deduct,
    /// violating loyalty integrity; zero is a no-op that masks caller bugs.
    public func accruePoints(userId: String, points: Int, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .manageMembership)
        guard points > 0 else { throw MembershipError.invalidPoints }
        guard var m = members[userId] else { throw MembershipError.notEnrolled }
        m.pointsBalance += points
        members[userId] = m
        try persistMember(m)
        logger.info(.lifecycle, "membership accrue userId=\(userId) points=+\(points)")
    }

    /// Redeems points. Self-redemption is allowed; otherwise requires `.manageMembership`.
    /// Rejects non-positive values: negative values would increase the balance,
    /// allowing free balance manipulation.
    public func redeemPoints(userId: String, points: Int, actingUser: User) throws {
        if actingUser.id != userId {
            try RolePolicy.enforce(user: actingUser, .manageMembership)
        }
        guard points > 0 else { throw MembershipError.invalidPoints }
        guard var m = members[userId] else { throw MembershipError.notEnrolled }
        guard m.pointsBalance >= points else { throw MembershipError.insufficientPoints }
        m.pointsBalance -= points
        members[userId] = m
        try persistMember(m)
        logger.info(.lifecycle, "membership redeem userId=\(userId) points=-\(points)")
    }

    /// Upgrades a member's tier. Requires `.manageMembership`.
    public func upgradeTier(userId: String, to tier: MembershipTier, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .manageMembership)
        guard var m = members[userId] else { throw MembershipError.notEnrolled }
        let prior = members[userId]
        m.tier = tier
        members[userId] = m
        do {
            try persistMember(m)
        } catch {
            members[userId] = prior
            logger.error(.lifecycle, "membership upgrade persist failed userId=\(userId)")
            throw error
        }
        logger.info(.lifecycle, "membership upgrade userId=\(userId) tier=\(tier.rawValue)")
    }

    /// Tags a member. Requires `.manageMembership`.
    public func tagMember(userId: String, tag: String, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .manageMembership)
        guard var m = members[userId] else { throw MembershipError.notEnrolled }
        let prior = members[userId]
        m.tags.insert(tag)
        members[userId] = m
        do {
            try persistMember(m)
        } catch {
            members[userId] = prior
            logger.error(.lifecycle, "membership tag persist failed userId=\(userId)")
            throw error
        }
    }

    // MARK: - Campaigns

    /// Creates a campaign. Requires `.manageMembership`.
    @discardableResult
    public func createCampaign(_ campaign: MarketingCampaign, actingUser: User) throws -> MarketingCampaign {
        try RolePolicy.enforce(user: actingUser, .manageMembership)
        let prior = campaigns[campaign.id]
        campaigns[campaign.id] = campaign
        do {
            try persistCampaign(campaign)
        } catch {
            if let prior { campaigns[campaign.id] = prior }
            else { campaigns.removeValue(forKey: campaign.id) }
            logger.error(.lifecycle, "campaign create persist failed id=\(campaign.id)")
            throw error
        }
        logger.info(.lifecycle, "campaign create id=\(campaign.id)")
        return campaign
    }

    public func campaign(_ id: String) -> MarketingCampaign? { campaigns[id] }

    public func allCampaigns() -> [MarketingCampaign] {
        campaigns.values.sorted { $0.id < $1.id }
    }

    /// Deactivates a campaign. Requires `.manageMembership`.
    public func deactivateCampaign(_ id: String, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .manageMembership)
        guard var c = campaigns[id] else { throw MembershipError.campaignNotFound }
        let prior = campaigns[id]
        c.active = false
        campaigns[id] = c
        do {
            try persistCampaign(c)
        } catch {
            campaigns[id] = prior
            logger.error(.lifecycle, "campaign deactivate persist failed id=\(id)")
            throw error
        }
    }

    /// Returns campaigns eligible for the given member based on tier and tags.
    public func eligibleCampaigns(for userId: String) -> [MarketingCampaign] {
        guard let m = members[userId] else { return [] }
        return campaigns.values
            .filter { $0.active }
            .filter { $0.targetTiers.contains(m.tier) }
            .filter { $0.targetTags.isEmpty || !$0.targetTags.isDisjoint(with: m.tags) }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Persistence

    private func persistMember(_ m: Member) throws {
        guard let persistence else { return }
        let data = try JSONEncoder().encode(m)
        try persistence.save(key: Self.persistencePrefix + m.userId, data: data)
    }

    private func persistCampaign(_ c: MarketingCampaign) throws {
        guard let persistence else { return }
        let data = try JSONEncoder().encode(c)
        try persistence.save(key: Self.campaignPrefix + c.id, data: data)
    }

    private func hydrate() {
        guard let persistence else { return }
        let decoder = JSONDecoder()
        do {
            for entry in try persistence.loadAll(prefix: Self.persistencePrefix) {
                if let m = try? decoder.decode(Member.self, from: entry.data) {
                    members[m.userId] = m
                }
            }
            for entry in try persistence.loadAll(prefix: Self.campaignPrefix) {
                if let c = try? decoder.decode(MarketingCampaign.self, from: entry.data) {
                    campaigns[c.id] = c
                }
            }
        } catch {
            logger.error(.lifecycle, "membership hydrate failed err=\(error)")
        }
    }
}
