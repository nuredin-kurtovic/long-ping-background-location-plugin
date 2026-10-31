import CoreLocation
import Foundation

protocol LocationControllerDelegate: AnyObject {
    func locationController(_ controller: LocationController, didReceive locations: [CLLocation])
    func locationControllerDidChangeAuthorization(_ controller: LocationController)
    func locationController(_ controller: LocationController, didFail error: Error)
    func locationControllerDidExitParkedRegion(_ controller: LocationController)
}

/// Owns the one CLLocationManager. Main thread only: CoreLocation delivers callbacks on the run loop of
/// the thread that created the manager.
final class LocationController: NSObject, CLLocationManagerDelegate {
    struct Settings: Equatable {
        var desiredAccuracy: CLLocationAccuracy
        var activityType: CLActivityType
        var showsBackgroundIndicator: Bool
    }

    static let parkedRegionId = "com.longping.parked"

    weak var delegate: LocationControllerDelegate?
    private let manager: CLLocationManager
    private let logger: EngineLogger
    private(set) var isUpdating = false
    private(set) var isMonitoringSignificantChanges = false
    private var applied: Settings?
    /// Whether Info.plist lets us run in the background; checked once, before touching the flag.
    let backgroundModeAvailable: Bool

    init(logger: EngineLogger) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.logger = logger
        manager = CLLocationManager()
        backgroundModeAvailable = InfoPlist.hasBackgroundLocationMode()
        super.init()
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = kCLDistanceFilterNone
        // Setting the delegate makes CoreLocation redeliver pending region / significant-change events
        // from the launch that woke us.
        manager.delegate = self
        if !backgroundModeAvailable {
            logger.error("location", "Info.plist UIBackgroundModes lacks 'location': tracking works in the foreground only")
        }
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var isFullAccuracy: Bool { manager.accuracyAuthorization == .fullAccuracy }
    var lastKnownLocation: CLLocation? { manager.location }

    // MARK: - Standard updates

    /// Starts (or retunes) continuous updates. Idempotent.
    func run(_ settings: Settings) {
        if applied != settings {
            manager.desiredAccuracy = settings.desiredAccuracy
            manager.activityType = settings.activityType
            if backgroundModeAvailable {
                // CoreLocation raises an Objective-C exception (uncatchable in Swift) when this is set
                // without the 'location' background mode, so it is guarded by the Info.plist check.
                manager.allowsBackgroundLocationUpdates = true
                manager.showsBackgroundLocationIndicator = settings.showsBackgroundIndicator
            }
            applied = settings
        }
        if !isUpdating {
            manager.startUpdatingLocation()
            isUpdating = true
            logger.debug("location", "standard updates started (accuracy \(settings.desiredAccuracy))")
        }
    }

    func stopUpdates() {
        guard isUpdating else { return }
        manager.stopUpdatingLocation()
        isUpdating = false
        logger.debug("location", "standard updates stopped")
    }

    /// Watchdog recovery: a stop/start cycle makes CoreLocation re-arm a session that went quiet.
    func restartUpdates() {
        guard isUpdating else { return }
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }

    // MARK: - Significant changes and the parked region (both relaunch a terminated app)

    func startSignificantChanges() {
        guard !isMonitoringSignificantChanges, CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        manager.startMonitoringSignificantLocationChanges()
        isMonitoringSignificantChanges = true
    }

    func stopSignificantChanges() {
        guard isMonitoringSignificantChanges else { return }
        manager.stopMonitoringSignificantLocationChanges()
        isMonitoringSignificantChanges = false
    }

    var parkedRegion: CLCircularRegion? {
        manager.monitoredRegions.first { $0.identifier == Self.parkedRegionId } as? CLCircularRegion
    }

    /// Exit-only circle; re-adding with the same identifier replaces the old one.
    func monitorParkedRegion(latitude: Double, longitude: Double, radius: Double) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            logger.warn("location", "region monitoring unavailable on this device")
            return
        }
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(center) else { return }
        let clamped = min(radius, manager.maximumRegionMonitoringDistance)
        let region = CLCircularRegion(center: center, radius: clamped, identifier: Self.parkedRegionId)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        logger.info("location", String(format: "parked region set (%.0f m)", clamped))
    }

    func removeParkedRegion() {
        // monitoredRegions survives relaunches, so this also clears a region left by a previous process.
        for region in manager.monitoredRegions where region.identifier == Self.parkedRegionId {
            manager.stopMonitoring(for: region)
            logger.info("location", "parked region removed")
        }
    }

    // MARK: - Permission

    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }
    func requestAlways() { manager.requestAlwaysAuthorization() }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        delegate?.locationController(self, didReceive: locations)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        delegate?.locationControllerDidChangeAuthorization(self)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        delegate?.locationController(self, didFail: error)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.parkedRegionId else { return }
        delegate?.locationControllerDidExitParkedRegion(self)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region?.identifier == Self.parkedRegionId else { return }
        logger.error("location", "parked region monitoring failed: \(error.localizedDescription)")
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        // pausesLocationUpdatesAutomatically is false, so this should never happen; log it if it does.
        logger.warn("location", "CoreLocation paused updates")
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        logger.info("location", "CoreLocation resumed updates")
    }
}
