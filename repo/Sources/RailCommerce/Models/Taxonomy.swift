import Foundation

public enum Region: String, CaseIterable, Codable, Sendable {
    case northeast, midwest, south, west, pacific
}

public enum Theme: String, CaseIterable, Codable, Sendable {
    case scenic, business, family, foodie, heritage, eco
}

public enum RiderType: String, CaseIterable, Codable, Sendable {
    case commuter, tourist, student, senior, member
}

public struct TaxonomyTag: Hashable, Codable, Sendable {
    public let region: Region?
    public let theme: Theme?
    public let riderType: RiderType?

    public init(region: Region? = nil, theme: Theme? = nil, riderType: RiderType? = nil) {
        self.region = region
        self.theme = theme
        self.riderType = riderType
    }

    /// Match is true if every non-nil component of `filter` equals this tag.
    public func matches(_ filter: TaxonomyTag) -> Bool {
        if let r = filter.region, r != region { return false }
        if let t = filter.theme, t != theme { return false }
        if let rt = filter.riderType, rt != riderType { return false }
        return true
    }
}
