import SwiftUI
import CircadianKit

/// Searchable airport picker.
///
/// Picking a real airport is what makes the rest of the engine honest: it yields an IANA
/// zone identifier (so daylight saving resolves per instant) and a latitude and longitude
/// (so "get bright light" can be checked against the actual sunrise). A UTC-offset stepper
/// can do neither.
struct PlacePicker: View {
    let title: String
    @Binding var selection: Place?

    @State private var query = ""
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if let selection {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(selection.displayName)
                            .foregroundStyle(.secondary)
                        Text(selection.timeZoneIdentifier)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Choose")
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                PlaceSearchList(selection: $selection, query: $query) {
                    isPresented = false
                }
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isPresented = false }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 520)
            #endif
        }
    }
}

private struct PlaceSearchList: View {
    @Binding var selection: Place?
    @Binding var query: String
    let onPick: () -> Void

    /// Search runs against 7,743 bundled airports; the database ranks hubs above regional
    /// fields so typing "lon" surfaces Heathrow rather than a grass strip in Ontario.
    private var results: [Place] {
        PlaceDatabase.shared.search(query, limit: 60)
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section("Major airports") { rows }
            } else {
                Section { rows }
            }
        }
        .searchable(text: $query, prompt: "City, airport or IATA code")
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var rows: some View {
        ForEach(results) { place in
            Button {
                selection = place
                onPick()
            } label: {
                HStack(spacing: 12) {
                    Text(place.iata)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .frame(width: 38)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.city)
                        Text(place.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if selection?.iata == place.iata {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
