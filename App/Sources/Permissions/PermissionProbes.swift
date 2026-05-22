import Foundation
import CoreBluetooth
import AVFoundation
import Contacts
import EventKit

/// Keys that mirror the brain's PERMISSION_CATALOG NSKey identifiers.
/// Adding a new permission means one entry here and one in
/// `feral-core/agents/permission_card.py:PERMISSION_CATALOG`.
enum PermissionKey: String, CaseIterable, Identifiable {
    case bluetooth = "NSBluetoothAlwaysUsageDescription"
    case microphone = "NSMicrophoneUsageDescription"
    case camera = "NSCameraUsageDescription"
    case contacts = "NSContactsUsageDescription"
    case calendars = "NSCalendarsFullAccessUsageDescription"
    case music = "NSAppleMusicUsageDescription"
    case location = "NSLocationWhenInUseUsageDescription"
    case health = "NSHealthShareUsageDescription"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .contacts: return "Contacts"
        case .calendars: return "Calendars"
        case .music: return "Apple Music"
        case .location: return "Location"
        case .health: return "Health"
        }
    }

    var icon: String {
        switch self {
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .microphone: return "mic.fill"
        case .camera: return "camera.fill"
        case .contacts: return "person.crop.circle"
        case .calendars: return "calendar"
        case .music: return "music.note"
        case .location: return "location.fill"
        case .health: return "heart.fill"
        }
    }

    /// Copy that explains why FERAL needs this permission. Sourced from
    /// the brain's PERMISSION_CATALOG so the wizard text matches what
    /// the chat cards show.
    var whyCopy: String {
        switch self {
        case .bluetooth:
            return "Connecting to FERAL-compatible glasses and wristbands requires Bluetooth permission."
        case .microphone:
            return "Voice commands and audio capture require permission to use the microphone."
        case .camera:
            return "Scanning QR codes for pairing and sharing scenes with the brain requires camera access."
        case .contacts:
            return "Looking up people by name so the brain can route \"call John\" to a real phone number."
        case .calendars:
            return "Reading upcoming events and creating new ones requires full Calendar access."
        case .music:
            return "Playing songs by title requires permission to use Apple Music."
        case .location:
            return "Location-aware answers require permission to read your iPhone's location while in use."
        case .health:
            return "Reading metrics like heart rate and steps from Apple Health."
        }
    }
}

/// Authorization status for a single permission.
enum PermissionStatus: String {
    case granted
    case denied
    case notDetermined
    case restricted
    case unknown

    var displayLabel: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        case .restricted: return "Restricted"
        case .unknown: return "Unknown"
        }
    }
}

/// Canonical ``x-apple.systempreferences:`` URL per permission so the
/// in-app card's "Open Settings" button always points at the right
/// pane after a denial.
///
/// Lane 11 R-PROD-004b: iOS-side counterpart of the Mac-side
/// ``security/macos_permissions.py:deeplink_for`` catalog. Brain code
/// and iOS code keep these in sync via the matching catalogs — any
/// new permission lands in BOTH (and in
/// ``feral-core/agents/permission_card.py:PERMISSION_CATALOG``).
extension PermissionKey {
    var deeplink: URL? {
        switch self {
        case .bluetooth:
            return URL(string: "App-prefs:Bluetooth")
        case .microphone:
            return URL(string: "App-prefs:Privacy&path=MICROPHONE")
        case .camera:
            return URL(string: "App-prefs:Privacy&path=CAMERA")
        case .contacts:
            return URL(string: "App-prefs:Privacy&path=CONTACTS")
        case .calendars:
            return URL(string: "App-prefs:Privacy&path=CALENDARS")
        case .music:
            return URL(string: "App-prefs:Privacy&path=MEDIA_LIBRARY")
        case .location:
            return URL(string: "App-prefs:Privacy&path=LOCATION")
        case .health:
            // Apple does not expose a deeplink directly to the Health
            // privacy pane; the in-app card directs the user through
            // Settings -> Health -> Data Access & Devices.
            return URL(string: "App-prefs:HEALTH")
        }
    }
}

/// Async helpers that read each iOS permission's current authorization
/// status and request access.
enum PermissionProbes {

    static func checkStatus(for key: PermissionKey) -> PermissionStatus {
        switch key {
        case .microphone:
            return mapAVStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            return mapAVStatus(AVCaptureDevice.authorizationStatus(for: .video))
        case .contacts:
            return mapCNStatus(CNContactStore.authorizationStatus(for: .contacts))
        case .calendars:
            return mapEKStatus(EKEventStore.authorizationStatus(for: .event))
        case .bluetooth:
            return mapCBStatus(CBManager.authorization)
        case .music:
            return checkMusicStatus()
        case .location:
            return checkLocationStatus()
        case .health:
            // HealthKit doesn't expose a global auth status check;
            // we report .unknown and let the user tap to request.
            return .unknown
        }
    }

    @discardableResult
    static func requestAccess(for key: PermissionKey) async -> Bool {
        switch key {
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .contacts:
            return await withCheckedContinuation { cont in
                CNContactStore().requestAccess(for: .contacts) { granted, _ in
                    cont.resume(returning: granted)
                }
            }
        case .calendars:
            return await withCheckedContinuation { cont in
                if #available(iOS 17.0, *) {
                    EKEventStore().requestFullAccessToEvents { granted, _ in
                        cont.resume(returning: granted)
                    }
                } else {
                    EKEventStore().requestAccess(to: .event) { granted, _ in
                        cont.resume(returning: granted)
                    }
                }
            }
        case .bluetooth:
            // Bluetooth prompts on first CBCentralManager init, which
            // the app already does via BluetoothSystemMonitor.
            return CBManager.authorization == .allowedAlways
        case .music:
            return await requestMusicAccess()
        case .location:
            return await requestLocationAccess()
        case .health:
            // HealthKit auth is per-type; the Devices tab handles
            // granular auth via HealthStore.
            return false
        }
    }

    // MARK: - Mappers

    private static func mapAVStatus(_ s: AVAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private static func mapCNStatus(_ s: CNAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .limited: return .granted
        @unknown default: return .unknown
        }
    }

    private static func mapEKStatus(_ s: EKAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .fullAccess, .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .writeOnly: return .denied
        @unknown default: return .unknown
        }
    }

    private static func mapCBStatus(_ s: CBManagerAuthorization) -> PermissionStatus {
        switch s {
        case .allowedAlways: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private static func checkMusicStatus() -> PermissionStatus {
        if #available(iOS 16.0, *) {
            // MusicKit doesn't have a sync status check prior to
            // requesting. Report unknown and let the user tap.
            return .unknown
        }
        return .unknown
    }

    private static func requestMusicAccess() async -> Bool {
        if #available(iOS 16.0, *) {
            // MusicKit authorization handled by the MusicKitSkill adapter
            return false
        }
        return false
    }

    private static func checkLocationStatus() -> PermissionStatus {
        // CLLocationManager needs an instance, but we can check the
        // class-level authorizationStatus for a quick read.
        if #available(iOS 14.0, *) {
            let mgr = CLLocationManagerProxy()
            switch mgr.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            @unknown default: return .unknown
            }
        }
        return .unknown
    }

    private static func requestLocationAccess() async -> Bool {
        // Location requires a delegate-based request. We rely on
        // the existing app flow to handle this; returning false
        // here indicates the wizard should guide the user.
        return false
    }
}

import CoreLocation

/// Minimal proxy to read CLLocationManager.authorizationStatus
/// without requiring a persistent delegate.
private final class CLLocationManagerProxy: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }
}
