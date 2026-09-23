import Foundation
import Network

/// A resolved IP's location, from the bundled offline database.
struct GeoLocation {
    let countryCode: String   // ISO 3166-1 alpha-2, e.g. "US"
    let countryName: String?  // e.g. "United States"; nil if the code isn't in `ISOCountryNames.table`
    let city: String?         // e.g. "Mountain View"; nil if the database has no city for this range
}

/// Offline IPv4 geolocation via a bundled, sorted-range binary (built by
/// `scripts/build_geoip_db.py` from DB-IP Lite City data, CC BY 4.0 — see
/// `NetBridge/Resources/GEOIP-ATTRIBUTION.md`). No network call, so no
/// destination IP is ever sent to a third party.
///
/// Loaded once via `Bundle.main` with `.mappedIfSafe`, so the multi-MB file
/// is mmap'd rather than held in RAM. Immutable after `init`, so `lookup(_:)`
/// is safe to call concurrently from every tunnel's own queue without a lock
/// — the same reasoning `DoHResolver.shared` already relies on.
final class GeoIPLookup {
    static let shared = GeoIPLookup()

    private struct Header {
        static let size = 8
    }
    private static let recordSize = 14

    private let data: Data?
    private let recordCount: Int
    private let cityTableOffset: Int

    private init() {
        guard let url = Bundle.main.url(forResource: "GeoIPv4", withExtension: "bin"),
              let mapped = try? Data(contentsOf: url, options: .mappedIfSafe),
              mapped.count >= Header.size else {
            DebugLog.important("geoip", "GeoIPv4.bin missing or unreadable — geolocation disabled")
            self.data = nil
            self.recordCount = 0
            self.cityTableOffset = 0
            return
        }
        let count = Int(Self.readUInt32(mapped, at: 0))
        let tableOffset = Int(Self.readUInt32(mapped, at: 4))
        guard tableOffset >= Header.size + count * Self.recordSize, tableOffset <= mapped.count else {
            DebugLog.important("geoip", "GeoIPv4.bin header inconsistent (count=\(count) tableOffset=\(tableOffset) size=\(mapped.count)) — geolocation disabled")
            self.data = nil
            self.recordCount = 0
            self.cityTableOffset = 0
            return
        }
        self.data = mapped
        self.recordCount = count
        self.cityTableOffset = tableOffset
        DebugLog.important("geoip", "GeoIPv4.bin loaded: \(count) records, \(mapped.count / 1024)KB")
    }

    func lookup(_ ip: String) -> GeoLocation? {
        guard let data = data, let address = IPv4Address(ip) else { return nil }
        let target = Self.asUInt32(address)

        var lo = 0
        var hi = recordCount - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let offset = Header.size + mid * Self.recordSize
            let start = Self.readUInt32(data, at: offset)
            let end = Self.readUInt32(data, at: offset + 4)
            if target < start {
                hi = mid - 1
            } else if target > end {
                lo = mid + 1
            } else {
                return record(at: offset, in: data)
            }
        }
        return nil
    }

    private func record(at offset: Int, in data: Data) -> GeoLocation {
        let base = data.startIndex + offset
        let countryCode = String(decoding: data[(base + 8)..<(base + 10)], as: UTF8.self)
        let cityIndex = Self.readUInt32(data, at: offset + 10)
        let city: String?
        if cityIndex == 0xFFFFFFFF {
            city = nil
        } else {
            city = Self.readCString(data, at: cityTableOffset + Int(cityIndex))
        }
        return GeoLocation(countryCode: countryCode, countryName: ISOCountryNames.table[countryCode], city: city)
    }

    private static func asUInt32(_ address: IPv4Address) -> UInt32 {
        let b = address.rawValue
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func readCString(_ data: Data, at offset: Int) -> String? {
        let base = data.startIndex + offset
        guard base < data.endIndex else { return nil }
        var end = base
        while end < data.endIndex, data[end] != 0 { end += 1 }
        return String(decoding: data[base..<end], as: UTF8.self)
    }
}

/// ISO 3166-1 alpha-2 → common English short name. Kept as a small static
/// table rather than bundling country names in `GeoIPv4.bin` itself, since
/// they're the same ~250 strings regardless of which IP database is used.
enum ISOCountryNames {
    static let table: [String: String] = [
        "AD": "Andorra", "AE": "United Arab Emirates", "AF": "Afghanistan", "AG": "Antigua and Barbuda",
        "AI": "Anguilla", "AL": "Albania", "AM": "Armenia", "AO": "Angola", "AQ": "Antarctica",
        "AR": "Argentina", "AS": "American Samoa", "AT": "Austria", "AU": "Australia", "AW": "Aruba",
        "AX": "Åland Islands", "AZ": "Azerbaijan", "BA": "Bosnia and Herzegovina", "BB": "Barbados",
        "BD": "Bangladesh", "BE": "Belgium", "BF": "Burkina Faso", "BG": "Bulgaria", "BH": "Bahrain",
        "BI": "Burundi", "BJ": "Benin", "BL": "Saint Barthélemy", "BM": "Bermuda", "BN": "Brunei",
        "BO": "Bolivia", "BQ": "Bonaire, Sint Eustatius and Saba", "BR": "Brazil", "BS": "Bahamas",
        "BT": "Bhutan", "BV": "Bouvet Island", "BW": "Botswana", "BY": "Belarus", "BZ": "Belize",
        "CA": "Canada", "CC": "Cocos Islands", "CD": "DR Congo", "CF": "Central African Republic",
        "CG": "Republic of the Congo", "CH": "Switzerland", "CI": "Côte d'Ivoire", "CK": "Cook Islands",
        "CL": "Chile", "CM": "Cameroon", "CN": "China", "CO": "Colombia", "CR": "Costa Rica",
        "CU": "Cuba", "CV": "Cape Verde", "CW": "Curaçao", "CX": "Christmas Island", "CY": "Cyprus",
        "CZ": "Czechia", "DE": "Germany", "DJ": "Djibouti", "DK": "Denmark", "DM": "Dominica",
        "DO": "Dominican Republic", "DZ": "Algeria", "EC": "Ecuador", "EE": "Estonia", "EG": "Egypt",
        "EH": "Western Sahara", "ER": "Eritrea", "ES": "Spain", "ET": "Ethiopia", "FI": "Finland",
        "FJ": "Fiji", "FK": "Falkland Islands", "FM": "Micronesia", "FO": "Faroe Islands", "FR": "France",
        "GA": "Gabon", "GB": "United Kingdom", "GD": "Grenada", "GE": "Georgia", "GF": "French Guiana",
        "GG": "Guernsey", "GH": "Ghana", "GI": "Gibraltar", "GL": "Greenland", "GM": "Gambia",
        "GN": "Guinea", "GP": "Guadeloupe", "GQ": "Equatorial Guinea", "GR": "Greece",
        "GS": "South Georgia and the South Sandwich Islands", "GT": "Guatemala", "GU": "Guam",
        "GW": "Guinea-Bissau", "GY": "Guyana", "HK": "Hong Kong", "HM": "Heard Island and McDonald Islands",
        "HN": "Honduras", "HR": "Croatia", "HT": "Haiti", "HU": "Hungary", "ID": "Indonesia",
        "IE": "Ireland", "IL": "Israel", "IM": "Isle of Man", "IN": "India",
        "IO": "British Indian Ocean Territory", "IQ": "Iraq", "IR": "Iran", "IS": "Iceland",
        "IT": "Italy", "JE": "Jersey", "JM": "Jamaica", "JO": "Jordan", "JP": "Japan", "KE": "Kenya",
        "KG": "Kyrgyzstan", "KH": "Cambodia", "KI": "Kiribati", "KM": "Comoros",
        "KN": "Saint Kitts and Nevis", "KP": "North Korea", "KR": "South Korea", "KW": "Kuwait",
        "KY": "Cayman Islands", "KZ": "Kazakhstan", "LA": "Laos", "LB": "Lebanon", "LC": "Saint Lucia",
        "LI": "Liechtenstein", "LK": "Sri Lanka", "LR": "Liberia", "LS": "Lesotho", "LT": "Lithuania",
        "LU": "Luxembourg", "LV": "Latvia", "LY": "Libya", "MA": "Morocco", "MC": "Monaco",
        "MD": "Moldova", "ME": "Montenegro", "MF": "Saint Martin", "MG": "Madagascar",
        "MH": "Marshall Islands", "MK": "North Macedonia", "ML": "Mali", "MM": "Myanmar",
        "MN": "Mongolia", "MO": "Macao", "MP": "Northern Mariana Islands", "MQ": "Martinique",
        "MR": "Mauritania", "MS": "Montserrat", "MT": "Malta", "MU": "Mauritius", "MV": "Maldives",
        "MW": "Malawi", "MX": "Mexico", "MY": "Malaysia", "MZ": "Mozambique", "NA": "Namibia",
        "NC": "New Caledonia", "NE": "Niger", "NF": "Norfolk Island", "NG": "Nigeria",
        "NI": "Nicaragua", "NL": "Netherlands", "NO": "Norway", "NP": "Nepal", "NR": "Nauru",
        "NU": "Niue", "NZ": "New Zealand", "OM": "Oman", "PA": "Panama", "PE": "Peru",
        "PF": "French Polynesia", "PG": "Papua New Guinea", "PH": "Philippines", "PK": "Pakistan",
        "PL": "Poland", "PM": "Saint Pierre and Miquelon", "PN": "Pitcairn Islands",
        "PR": "Puerto Rico", "PS": "Palestine", "PT": "Portugal", "PW": "Palau", "PY": "Paraguay",
        "QA": "Qatar", "RE": "Réunion", "RO": "Romania", "RS": "Serbia", "RU": "Russia",
        "RW": "Rwanda", "SA": "Saudi Arabia", "SB": "Solomon Islands", "SC": "Seychelles",
        "SD": "Sudan", "SE": "Sweden", "SG": "Singapore", "SH": "Saint Helena", "SI": "Slovenia",
        "SJ": "Svalbard and Jan Mayen", "SK": "Slovakia", "SL": "Sierra Leone", "SM": "San Marino",
        "SN": "Senegal", "SO": "Somalia", "SR": "Suriname", "SS": "South Sudan",
        "ST": "São Tomé and Príncipe", "SV": "El Salvador", "SX": "Sint Maarten", "SY": "Syria",
        "SZ": "Eswatini", "TC": "Turks and Caicos Islands", "TD": "Chad",
        "TF": "French Southern Territories", "TG": "Togo", "TH": "Thailand", "TJ": "Tajikistan",
        "TK": "Tokelau", "TL": "Timor-Leste", "TM": "Turkmenistan", "TN": "Tunisia", "TO": "Tonga",
        "TR": "Turkey", "TT": "Trinidad and Tobago", "TV": "Tuvalu", "TW": "Taiwan",
        "TZ": "Tanzania", "UA": "Ukraine", "UG": "Uganda", "UM": "U.S. Minor Outlying Islands",
        "US": "United States", "UY": "Uruguay", "UZ": "Uzbekistan", "VA": "Vatican City",
        "VC": "Saint Vincent and the Grenadines", "VE": "Venezuela", "VG": "British Virgin Islands",
        "VI": "U.S. Virgin Islands", "VN": "Vietnam", "VU": "Vanuatu", "WF": "Wallis and Futuna",
        "WS": "Samoa", "YE": "Yemen", "YT": "Mayotte", "ZA": "South Africa", "ZM": "Zambia",
        "ZW": "Zimbabwe",
    ]
}
