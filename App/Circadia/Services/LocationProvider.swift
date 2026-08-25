import Foundation
import CoreLocation
import Observation
import CircadianKit

/// A one-shot location lookup used only to pre-select the departure airport.
///
/// Deliberately optional and deliberately transient: the plan itself needs the airport's
/// coordinates, not the user's, and those come from the bundled database. Nothing is
/// stored, and declining the permission costs nothing but a tap.
@MainActor
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    enum State: Equatable {
        case idle, requesting, denied
        case resolved(Place)
        case failed(String)
    }

    var state: State = .idle

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Returns the nearest major airport, or `nil` if the user declines or it fails.
    func nearestAirport() async -> Place? {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            state = .denied
            return nil
        default:
            break
        }

        state = .requesting
        let location = await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = continuation
            manager.requestLocation()
        }

        guard let location else {
            if state == .requesting { state = .failed("Could not get a location fix.") }
            return nil
        }
        let place = PlaceDatabase.shared.nearest(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        if let place { state = .resolved(place) }
        return place
    }

    private func finish(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let first = locations.first
        Task { @MainActor in self.finish(first) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.state = .failed(message)
            self.finish(nil)
        }
    }
}
