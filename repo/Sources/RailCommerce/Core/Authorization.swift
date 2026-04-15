import Foundation

/// Thrown when a user attempts an operation they are not permitted to perform.
public enum AuthorizationError: Error, Equatable {
    case forbidden(required: Permission)
}

public extension RolePolicy {
    /// Throws `AuthorizationError.forbidden` unless `user`'s role includes `permission`.
    static func enforce(user: User, _ permission: Permission) throws {
        guard can(user.role, permission) else {
            throw AuthorizationError.forbidden(required: permission)
        }
    }
}
