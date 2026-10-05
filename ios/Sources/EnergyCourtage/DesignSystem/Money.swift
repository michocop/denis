import Foundation

/// Euros as they are written in France: "1 500 €", "12 500,50 €".
///
/// Foundation groups French thousands with a narrow no-break space (U+202F),
/// which neither Sora nor Manrope has: the space vanished and "1 500 €" was
/// drawn "1500 €". A plain no-break space, which both faces carry, keeps the
/// grouping and still never wraps between the digits and the sign.
public enum Money {
    public static func euros(_ amount: Decimal, cents: Bool = false) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "fr_FR")
        f.minimumFractionDigits = cents ? 2 : 0
        f.maximumFractionDigits = cents ? 2 : 0
        return (f.string(from: amount as NSDecimalNumber) ?? "—")
            .replacingOccurrences(of: "\u{202F}", with: "\u{00A0}")
    }
}
