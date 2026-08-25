import SwiftUI
import CircadianKit

/// The disclaimer, in the two shapes the app needs it: a full panel for onboarding and
/// the about screen, and a compact always-visible footer for the plan.
struct DisclaimerPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Educational tool, not medical advice", systemImage: "info.circle.fill")
                .font(.headline)
                .foregroundStyle(.tint)

            Text(CircadianPlan.disclaimer)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Melatonin is a prescription medicine in some countries and is not suitable for everyone. Talk to a pharmacist or doctor before taking it, especially if you are pregnant, taking other medication, or have a medical condition.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

/// Compact footer. Kept prominent enough to read, quiet enough not to shout.
struct DisclaimerFooter: View {
    @State private var showingFull = false

    var body: some View {
        Button {
            showingFull = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("Independent educational planner — not medical advice, not affiliated with Timeshifter.")
                    .multilineTextAlignment(.leading)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingFull) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        DisclaimerPanel()
                        AboutTheScience()
                    }
                    .padding()
                }
                .navigationTitle("About")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingFull = false }
                    }
                }
            }
        }
    }
}

/// Where the numbers come from. Being able to answer "why is it telling me this?" is the
/// difference between advice and superstition.
struct AboutTheScience: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where the numbers come from")
                .font(.headline)

            ForEach(Citation.all) { citation in
                VStack(alignment: .leading, spacing: 3) {
                    Text(citation.what).font(.subheadline.weight(.medium))
                    Text(citation.source).font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("This is an independent reimplementation built from the published literature. It is not Timeshifter's algorithm, which is proprietary and not public.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Citation: Identifiable {
    let id = UUID()
    let what: String
    let source: String

    static let all: [Citation] = [
        Citation(
            what: "Light phase-response curve",
            source: "Khalsa, Jewett, Cajochen & Czeisler (2003) J Physiol 549:945. A 6.7 h bright-light pulse: maximum advance 2.32 h, maximum delay 2.70 h, no significant dead zone."
        ),
        Citation(
            what: "How duration scales the response",
            source: "St Hilaire et al. (2012) J Physiol 590:3035. A 1 h pulse reaches ~40% of the 6.7 h amplitude — the response is strongly sub-linear in duration."
        ),
        Citation(
            what: "How brightness scales the response",
            source: "Zeitzer, Dijk, Kronauer, Brown & Czeisler (2000) J Physiol 526:695. Half the maximum response comes from about 120 lux, so ordinary room light already matters."
        ),
        Citation(
            what: "Melatonin phase-response curve",
            source: "Burgess, Revell & Eastman (2008) J Physiol 586:639 and Burgess et al. (2010) JCEM 95:3325. Advances are largest for afternoon dosing a few hours before melatonin onset."
        ),
        Citation(
            what: "Where your temperature minimum sits",
            source: "Estimated from your habitual sleep and chronotype, blending the wake-time anchor used by Eastman & Burgess with the melatonin-onset anchor of Burgess et al. (2003)."
        ),
        Citation(
            what: "Sunrise and sunset",
            source: "NOAA solar position algorithm, after Meeus, Astronomical Algorithms. Computed on device from the airport's coordinates — no network, no location permission needed."
        )
    ]
}
