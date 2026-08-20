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

    /// Chip colour. Green stays reserved for diesel to match the fuel pill and
    /// timeline icon elsewhere in the app, so E85 uses yellow (ethanol) instead.
    public var color: Color {
        switch self {
        case .regular: return .blue
        case .midgrade: return .teal
        case .premium: return .purple
        case .e85: return .yellow
        case .diesel: return .green
        case .other: return .gray
        }
    }
}

public enum FuelUnit: String, Codable, CaseIterable, Identifiable {
    case gallons = "Gallons"
    case liters = "Liters"
    case kwh = "kWh"
    public var id: String { rawValue }
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
    case oilChange = "Oil Change", tires = "Tires", brakes = "Brakes", battery = "Battery", general = "General"
    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .oilChange: return "drop.fill"
        case .tires: return "dot.circle"
        case .brakes: return "exclamationmark.circle"
        case .battery: return "battery.100"
        case .general: return "wrench.adjustable"
        }
    }

    public var color: Color {
        switch self {
        case .oilChange: return .orange
        case .tires: return .gray
        case .brakes: return .red
        case .battery: return .green
        case .general: return .blue
        }
    }

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Service Type"
    public static let caseDisplayRepresentations: [ServiceType: DisplayRepresentation] = [
        .oilChange: "Oil Change",
        .tires: "Tires",
        .brakes: "Brakes",
        .battery: "Battery",
        .general: "General"
    ]
}
#else
public enum ServiceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case oilChange = "Oil Change", tires = "Tires", brakes = "Brakes", battery = "Battery", general = "General"
    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .oilChange: return "drop.fill"
        case .tires: return "dot.circle"
        case .brakes: return "exclamationmark.circle"
        case .battery: return "battery.100"
        case .general: return "wrench.adjustable"
        }
    }

    public var color: Color {
        switch self {
        case .oilChange: return .orange
        case .tires: return .gray
        case .brakes: return .red
        case .battery: return .green
        case .general: return .blue
        }
    }
}
#endif

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
