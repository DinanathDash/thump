import Foundation

/// Defines the environmental operating surface profile for Thump chassis tap detection.
public enum ThumpSurfaceProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case dynamic = "dynamic"
    case desk = "desk"
    case lap = "lap"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dynamic:
            return "Dynamic (Desk & Lap)"
        case .desk:
            return "On Desk (Rigid)"
        case .lap:
            return "On Lap (Soft)"
        }
    }

    public var iconName: String {
        switch self {
        case .dynamic:
            return "xmark.triangle.circle.square.fill"
        case .desk:
            return "table.furniture"
        case .lap:
            return "sofa"
        }
    }

    public var summaryDescription: String {
        switch self {
        case .dynamic:
            return "Automatically detects chassis tilt and surface cushioning to adapt sensitivity seamlessly between desk and lap."
        case .desk:
            return "Tuned for hard, rigid tables with firm chassis bounce. Suppresses keyboard vibrations."
        case .lap:
            return "Boosts sensitivity to capture taps softened by lap clothing, legs, or soft furniture."
        }
    }

    public var defaultThreshold: Double {
        switch self {
        case .dynamic:
            return 0.020
        case .desk:
            return 0.022
        case .lap:
            return 0.016
        }
    }

    public var defaultGroupingWindow: Double {
        switch self {
        case .dynamic:
            return 0.60
        case .desk:
            return 0.58
        case .lap:
            return 0.62
        }
    }

    public var defaultCooldown: Double {
        switch self {
        case .dynamic:
            return 0.052
        case .desk:
            return 0.055
        case .lap:
            return 0.050
        }
    }

    public static func from(raw: String?) -> ThumpSurfaceProfile {
        guard let raw, let profile = ThumpSurfaceProfile(rawValue: raw) else {
            return .dynamic
        }
        return profile
    }
}
