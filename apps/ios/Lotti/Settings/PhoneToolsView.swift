import AlarmKit
import AVFoundation
import CoreLocation
import EventKit
import LottiKit
import SwiftUI
import UIKit

/// What Lotti may use on this phone: permissions, and which calendars it reads when offline.
struct PhoneToolsView: View {
    @State private var places = LocationAsker()
    @State private var refresh = 0

    var body: some View {
        List {
            Section {
                permission("Location", status(places.manager.authorizationStatus), "location")
                permission("Reminders", reminders, "bell")
                permission("Calendars", calendars, "calendar")
                permission("Alarms and timers", alarms, "timer")
                permission("Microphone", microphone, "mic")
                Button("Allow location") {
                    places.manager.requestWhenInUseAuthorization()
                    refresh += 1
                }
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Lotti Brain reads your location and reminders through the phone only while you ask, and every location read is logged under Privacy.")
            }
            Section {
                NavigationLink("Calendars") { CalendarsView() }
            } footer: {
                Text("The calendars used for the today view and when Lotti Brain can't be reached.")
            }
        }
        .navigationTitle("Phone tools")
        .id(refresh)
    }

    private func permission(_ name: String, _ state: String, _ icon: String) -> some View {
        LabeledContent {
            Text(state).foregroundStyle(state == "Allowed" ? .green : .secondary)
        } label: {
            Label(name, systemImage: icon)
        }
    }

    private func status(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: "Allowed"
        case .denied, .restricted: "Off"
        default: "Not asked"
        }
    }

    private var reminders: String {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: "Allowed"
        case .notDetermined: "Not asked"
        default: "Off"
        }
    }

    private var calendars: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: "Allowed"
        case .notDetermined: "Not asked"
        default: "Off"
        }
    }

    private var alarms: String {
        switch AlarmManager.shared.authorizationState {
        case .authorized: "Allowed"
        case .notDetermined: "Not asked"
        default: "Off"
        }
    }

    private var microphone: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: "Allowed"
        case .undetermined: "Not asked"
        default: "Off"
        }
    }
}

/// Keeps a location manager alive while its permission prompt is up.
@MainActor
@Observable
final class LocationAsker {
    let manager = CLLocationManager()
}
