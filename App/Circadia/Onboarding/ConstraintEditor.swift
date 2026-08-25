import SwiftUI
import CircadianKit

/// Adds a practicality constraint: the "I have a meeting at seven" escape hatch.
struct ConstraintEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (PracticalityConstraint) -> Void

    @State private var kind: PracticalityConstraint.Kind = .mustBeAwake
    @State private var label = ""
    @State private var from = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    @State private var to = Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: .now) ?? .now
    @State private var appliesToOneDay = false
    @State private var dayIndex = 1

    var body: some View {
        NavigationStack {
            Form {
                Section("What kind") {
                    Picker("Kind", selection: $kind) {
                        ForEach(PracticalityConstraint.Kind.allCases, id: \.self) { kind in
                            Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)

                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("When") {
                    DatePicker("From", selection: $from, displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: $to, displayedComponents: .hourAndMinute)
                    Toggle("Only on one day", isOn: $appliesToOneDay)
                    if appliesToOneDay {
                        Stepper(dayLabel, value: $dayIndex, in: -3...14)
                    }
                }

                Section("Name it") {
                    TextField("e.g. board meeting", text: $label)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add commitment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private var dayLabel: String {
        if dayIndex < 0 { return "\(-dayIndex) day(s) before you fly" }
        if dayIndex == 0 { return "Departure day" }
        return "Day \(dayIndex)"
    }

    private var explanation: String {
        switch kind {
        case .mustBeAwake:
            "Circadia will not schedule sleep or a nap here, and will shorten the night at whichever end costs you less."
        case .brightLightUnavoidable:
            "Circadia will stop telling you to avoid light here. Instead it offers mitigation and subtracts the shift you lose from that day's progress."
        case .brightLightUnavailable:
            "Circadia will move the bright-light window out of this period, or fall back to a lamp, and tell you how much effect that costs."
        case .noMelatonin:
            "No melatonin will be suggested in this window. Set it to cover the whole day to rule it out entirely."
        case .noCaffeine:
            "No caffeine will be suggested in this window."
        }
    }

    private func save() {
        let calendar = Calendar.current
        let fromComponents = calendar.dateComponents([.hour, .minute], from: from)
        let toComponents = calendar.dateComponents([.hour, .minute], from: to)
        onSave(PracticalityConstraint(
            kind: kind,
            dayIndex: appliesToOneDay ? dayIndex : nil,
            from: ClockTime(hour: fromComponents.hour ?? 9, minute: fromComponents.minute ?? 0),
            to: ClockTime(hour: toComponents.hour ?? 11, minute: toComponents.minute ?? 0),
            label: label.isEmpty ? kind.displayName : label
        ))
        dismiss()
    }
}

struct ConstraintRow: View {
    let constraint: PracticalityConstraint
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: constraint.kind.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(constraint.label).font(.subheadline)
                Text("\(constraint.kind.displayName) · \(constraint.from.description)–\(constraint.to.description)\(scope)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var scope: String {
        guard let day = constraint.dayIndex else { return " · every day" }
        if day < 0 { return " · \(-day)d before" }
        return day == 0 ? " · departure day" : " · day \(day)"
    }
}
