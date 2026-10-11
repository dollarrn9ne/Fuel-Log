import SwiftUI
#if canImport(AppIntents)
import AppIntents
#endif

// MARK: - App Theme

public enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    public var id: String { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Fuel

public enum FuelType: String, Codable, CaseIterable, Identifiable {
    case gas = "Gasoline"
    case diesel = "Diesel"
    case flexFuel = "Flex-Fuel (E85)"
    case plugInHybrid = "Plug-In Hybrid (PHEV)"
    case electric = "Electric (EV)"
    public var id: String { rawValue }

    /// Grades that make sense to offer for this vehicle at the pump.
    public var availableGrades: [FuelGrade] {
        switch self {
        case .gas, .plugInHybrid: return [.regular, .midgrade, .premium, .other]
        case .flexFuel: return [.e85, .regular, .midgrade, .premium, .other]
        case .diesel: return [.diesel, .other]
        case .electric: return []
        }
    }

    /// The grade preselected for a new fill-up.
    public var defaultGrade: FuelGrade? {
        switch self {
        case .gas, .plugInHybrid: return .regular
        case .flexFuel: return .e85
        case .diesel: return .diesel
        case .electric: return nil
        }
    }
}

/// What was actually put in the tank on a given fill-up. Tracked per fill-up
/// because flex-fuel drivers alternate between E85 and gasoline, and the two
/// have materially different energy content (E85 yields noticeably lower MPG),
/// so blending them into one average misrepresents both.
public enum FuelGrade: String, Codable, CaseIterable, Identifiable {
    case regular = "Regular"
    case midgrade = "Midgrade"
    case premium = "Premium"
    case e85 = "E85"
    case diesel = "Diesel"
    case other = "Other"
    public var id: String { rawValue }
}

public enum FuelUnit: String, Codable, CaseIterable, Identifiable {
    case gallons = "Gallons"
    case liters = "Liters"
    case kwh = "kWh"
    public var id: String { rawValue }
}

/// Where an EV charging session happened. Each behaves differently for cost:
/// home uses the household's utility rate, public Level 2 usually has a
/// per-kWh price (occasionally free), and DC fast charging works like a gas
/// station - a brand, a per-kWh price, and sometimes a session fee.
public enum ChargerType: String, Codable, CaseIterable, Identifiable {
    case home = "Home"
    case publicLevel2 = "Public Level 2"
    case dcFast = "DC Fast"
    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .publicLevel2: return "bolt.fill"
        case .dcFast: return "bolt.horizontal.fill"
        }
    }

    /// Public networks sometimes add a flat fee per session; a home charger
    /// never does, so the field is hidden there.
    public var canHaveSessionFee: Bool { self != .home }
}

// MARK: - Odometer & Efficiency

public enum OdometerUnit: String, Codable, CaseIterable, Identifiable {
    case miles = "Miles"
    case kilometers = "Kilometers"
    public var id: String { rawValue }
}

public enum EfficiencyUnit: String, Codable, CaseIterable, Identifiable {
    case mpgUS = "MPG (US)"
    case mpgUK = "MPG (UK)"
    case l100km = "L/100 km"
    case kmPerLitre = "km/L"
    case miPerKWh = "mi/kWh"
    case kmPerKWh = "km/kWh"
    public var id: String { rawValue }
}

// MARK: - Currency

public enum Currency: String, Codable, CaseIterable, Identifiable {
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case cad = "CAD"
    case aud = "AUD"
    case jpy = "JPY"
    case inr = "INR"
    case chf = "CHF"
    case cny = "CNY"
    case nzd = "NZD"

    public var id: String { rawValue }
}

// MARK: - Service Type

#if canImport(AppIntents)
public enum ServiceType: String, Codable, CaseIterable, Identifiable, Sendable, AppEnum {
    case oilChange = "Oil Change", tires = "Tires", brakes = "Brakes", battery = "Battery", general = "General", adBlue = "AdBlue / DEF"
    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .oilChange: return "drop.fill"
        case .tires: return "dot.circle"
        case .brakes: return "exclamationmark.circle"
        case .battery: return "battery.100"
        case .general: return "wrench.adjustable"
        case .adBlue: return "drop.triangle.fill"
        }
    }

    public var color: Color {
        switch self {
        case .oilChange: return .orange
        case .tires: return .gray
        case .brakes: return .red
        case .battery: return .green
        case .general: return .blue
        case .adBlue: return .cyan
        }
    }

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Service Type"
    public static let caseDisplayRepresentations: [ServiceType: DisplayRepresentation] = [
        .oilChange: "Oil Change",
        .tires: "Tires",
        .brakes: "Brakes",
        .battery: "Battery",
        .general: "General",
        .adBlue: "AdBlue / DEF"
    ]
}
#else
public enum ServiceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case oilChange = "Oil Change", tires = "Tires", brakes = "Brakes", battery = "Battery", general = "General", adBlue = "AdBlue / DEF"
    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .oilChange: return "drop.fill"
        case .tires: return "dot.circle"
        case .brakes: return "exclamationmark.circle"
        case .battery: return "battery.100"
        case .general: return "wrench.adjustable"
        case .adBlue: return "drop.triangle.fill"
        }
    }

    public var color: Color {
        switch self {
        case .oilChange: return .orange
        case .tires: return .gray
        case .brakes: return .red
        case .battery: return .green
        case .general: return .blue
        case .adBlue: return .cyan
        }
    }
}
#endif

// MARK: - AdBlue / DEF

/// The same urea solution is sold as "AdBlue" in Europe, Australia and most of
/// the world, and as "DEF" (Diesel Exhaust Fluid) in the US and Canada. The
/// stored value is neutral ("AdBlue / DEF"); only what the user sees follows
/// their region.
public enum AdBlueNaming {
    private static let defRegions: Set<String> = ["US", "CA", "PR", "GU", "VI", "AS", "MP"]

    /// The short name for the user's region.
    public static var name: String { name(forRegion: Locale.current.region?.identifier) }

    /// The name for a region code ("US", "DE", ...). Anywhere not known to say
    /// "DEF" - including no region at all - says "AdBlue".
    public static func name(forRegion region: String?) -> String {
        guard let region else { return "AdBlue" }
        return defRegions.contains(region.uppercased()) ? "DEF" : "AdBlue"
    }
}

public extension ServiceType {
    /// What to call this type on screen. Everything but AdBlue is its own name.
    var displayName: String { self == .adBlue ? AdBlueNaming.name : rawValue }
}

// MARK: - Import / Export

public enum ExportEncoding: String, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case ascii = "ASCII"
    case windows1252 = "Windows-1252"
    case isoLatin1 = "ISO Latin 1"
    case isoLatin2 = "ISO Latin 2"
    case utf16 = "UTF-16"
    case utf32 = "UTF-32"
    case shiftJIS = "Shift JIS"
    case macRoman = "Mac OS Roman"
    case japaneseEUC = "Japanese (EUC)"

    public var id: String { rawValue }
    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .ascii: return .ascii
        case .windows1252: return .windowsCP1252
        case .isoLatin1: return .isoLatin1
        case .isoLatin2: return .isoLatin2
        case .utf16: return .utf16
        case .utf32: return .utf32
        case .shiftJIS: return .shiftJIS
        case .macRoman: return .macOSRoman
        case .japaneseEUC: return .japaneseEUC
        }
    }
}

public enum ImportSource: String, CaseIterable, Identifiable {
    case fuelio = "Fuelio"
    case fuelly = "Fuelly"
    case mileIQ = "MileIQ"
    case roadTrip = "Road Trip"
    case none = "Auto-Detect"

    public var id: String { rawValue }
}

// MARK: - Tax

public enum TaxTimeframe: String, CaseIterable, Identifiable {
    case allTime = "All Time"
    case year = "Year"
    case month = "Month"
    case custom = "Custom"
    public var id: String { rawValue }
}
