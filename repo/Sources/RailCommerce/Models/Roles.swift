import Foundation

public enum Role: String, CaseIterable, Codable, Sendable {
    case customer
    case salesAgent
    case contentEditor
    case contentReviewer
    case customerService
    case administrator
}

public enum Permission: String, CaseIterable, Codable, Sendable {
    case browseContent
    case purchase
    case manageAfterSales
    case processTransaction
    case manageInventory
    case draftContent
    case reviewContent
    case publishContent
    case handleServiceTickets
    case sendStaffMessage
    case configureSystem
    case manageUsers
    case matchTalent
    case manageMembership
}

public enum RolePolicy {
    /// Authoritative role → permission map as required by the prompt.
    public static let matrix: [Role: Set<Permission>] = [
        .customer: [.browseContent, .purchase, .manageAfterSales],
        .salesAgent: [.processTransaction, .manageInventory, .browseContent],
        .contentEditor: [.draftContent, .browseContent],
        .contentReviewer: [.reviewContent, .publishContent, .browseContent],
        .customerService: [.handleServiceTickets, .sendStaffMessage, .manageAfterSales, .browseContent],
        .administrator: Set(Permission.allCases)
    ]

    public static func can(_ role: Role, _ permission: Permission) -> Bool {
        // Every role has an entry in the matrix; force-access is safe.
        matrix[role]!.contains(permission)
    }
}

public struct User: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let role: Role

    public init(id: String, displayName: String, role: Role) {
        self.id = id
        self.displayName = displayName
        self.role = role
    }
}

/// Alias for `User` that does NOT collide with `RealmSwift.User` when a caller
/// imports both this module and RealmSwift (typical in the iOS app target).
/// Always prefer `RCUser` in files that import `RealmSwift`.
public typealias RCUser = User
