import SwiftUI

/// Settings ▸ Input: every operator and function inline calculation understands, with an example
/// whose result is computed by `InlineCalculator` itself (`InlineCalculationHelpTests` checks each one).
struct InlineCalculationReference {
    struct Row: Identifiable {
        let example: String
        let summary: LocalizedStringResource
        var id: String { example }

        /// The ghost the example line shows, without its leading space.
        var result: String? {
            InlineCalculator.proposal(forLine: example)?.ghost.trimmingCharacters(in: .whitespaces)
        }
    }

    struct Group: Identifiable {
        let title: LocalizedStringResource
        let rows: [Row]
        var id: String { rows[0].example }
    }

    static let groups: [Group] = [
        Group(title: "Basic", rows: [
            Row(example: "12 + 8 - 3", summary: "Add and subtract"),
            Row(example: "12 * 8 / 4", summary: "Multiply and divide (× and ÷ also work)"),
            Row(example: "(2 + 3) * 4", summary: "Parentheses"),
            Row(example: "2^10", summary: "Power (** also works)"),
            Row(example: "sqrt(144)", summary: "Square root (√ also works)"),
            Row(example: "200 * 15%", summary: "Percent: divides by 100"),
            Row(example: "mod(10, 3)", summary: "Remainder, with the sign of the divisor"),
            Row(example: "abs(-10)", summary: "Absolute value"),
        ]),
        Group(title: "Functions", rows: [
            Row(example: "cbrt(27)", summary: "Cube root"),
            Row(example: "root(16, 4)", summary: "Root of any degree"),
            Row(example: "max(10, 20, 30)", summary: "Largest value"),
            Row(example: "min(10, 20, 30)", summary: "Smallest value"),
            Row(example: "avg(10, 20, 30)", summary: "Average"),
            Row(example: "round(3.14159, 2)", summary: "Round to decimal places (halves round away from zero)"),
            Row(example: "floor(3.8)", summary: "Round down"),
            Row(example: "ceil(3.2)", summary: "Round up"),
            Row(example: "5!", summary: "Factorial"),
            Row(example: "log(100)", summary: "Base-10 logarithm (log10 also works)"),
            Row(example: "log(8, 2)", summary: "Logarithm to any base (log2 for base 2)"),
            Row(example: "ln(10)", summary: "Natural logarithm"),
        ]),
        Group(title: "Scientific", rows: [
            Row(example: "sin(30°)", summary: "Sine, cosine, tangent: sin, cos, tan; radians, or degrees with °"),
            Row(example: "asin(1)", summary: "Inverse sine, cosine, tangent: asin, acos, atan; in radians"),
            Row(example: "exp(1)", summary: "e raised to a power"),
            Row(example: "2 * pi", summary: "Constants pi (π) and e"),
        ]),
    ]
}

struct InlineCalculationHelp: View {
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Supported operations", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(InlineCalculationReference.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.textPrimary)
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                            ForEach(group.rows) { row in
                                GridRow {
                                    Text(row.example + " " + (row.result ?? ""))
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(Color.textPrimary)
                                        .textSelection(.enabled)
                                        .fixedSize()
                                    Text(row.summary)
                                        .font(.callout)
                                        .foregroundStyle(Color.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                Text("Exact results are shown with =, rounded ones with ≈ (12 significant digits). Function names ignore case, and fullwidth digits and symbols work too. Write = at the end of the line to get only the number.")
                    .settingsFootnote()
            }
            .padding(.top, 6)
        }
    }
}
