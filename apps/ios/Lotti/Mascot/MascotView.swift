import LottiKit
import SwiftUI

/// UserDefaults key and default of the Settings → Glasses "Mascot" switch.
enum MascotSetting {
    static let key = "mascotEnabled"
    static let defaultValue = true

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// The big raccoon (empty chat). Renders nothing while the mascot is switched off.
struct MascotView: View {
    let host: MascotHost
    var body: some View {
        MascotPoseDriver(host: host) { pose in
            RaccoonView(glassesProgress: pose.glasses, headPitch: pose.pitch, headRoll: pose.roll, headYaw: pose.yaw)
        }
    }
}

/// The small head-only raccoon (chat header), about 32 pt. Renders nothing while switched off.
struct MascotAvatarView: View {
    let host: MascotHost
    var size: CGFloat = 32
    var body: some View {
        MascotPoseDriver(host: host) { pose in
            RaccoonAvatar(glassesProgress: pose.glasses, headPitch: pose.pitch, headRoll: pose.roll, headYaw: pose.yaw)
                .frame(width: size, height: size)
        }
    }
}

/// The values the art is drawn from.
struct MascotPose: Equatable {
    var glasses = 0.0, pitch = 0.0, roll = 0.0, yaw = 0.0
}

/// Observes the controller, eases its output into a `MascotPose` the art can animate, and keeps
/// the host's ref-count right (foreground and visible and enabled only).
private struct MascotPoseDriver<Content: View>: View {
    let host: MascotHost
    @ViewBuilder let content: (MascotPose) -> Content

    @AppStorage(MascotSetting.key) private var enabled = MascotSetting.defaultValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pose: MascotPose
    @State private var visible = false
    @State private var held = false

    init(host: MascotHost, @ViewBuilder content: @escaping (MascotPose) -> Content) {
        self.host = host
        self.content = content
        // First appearance shows the current state without animating.
        _pose = State(initialValue: MascotPose(glasses: host.controller.glassesOn ? 1 : 0))
    }

    private var controller: MascotController { host.controller }

    var body: some View {
        Group {
            if enabled {
                content(pose)
                    .accessibilityHidden(true)
                    .onChange(of: controller.glassesOn) { _, on in applyGlasses(on) }
                    .onChange(of: controller.pitch) { applyHead() }
                    .onChange(of: controller.roll) { applyHead() }
                    .onChange(of: controller.yaw) { applyHead() }
                    .onChange(of: reduceMotion) { applyHead(); applyGlasses(controller.glassesOn, animated: false) }
            }
        }
        .onAppear { visible = true; sync() }
        .onDisappear { visible = false; sync() }
        .onChange(of: scenePhase) { sync() }
        .onChange(of: enabled) { sync() }
    }

    /// Holds the controller exactly while on screen, in the foreground, and switched on.
    private func sync() {
        let want = visible && enabled && scenePhase == .active
        host.setEnabled(enabled)
        if want, !held {
            held = true
            host.acquire()
            applyGlasses(controller.glassesOn, animated: false)
            applyHead()
        } else if !want, held {
            held = false
            host.release()
        }
    }

    private func applyGlasses(_ on: Bool, animated explicit: Bool? = nil) {
        let target = on ? 1.0 : 0.0
        let animate = (explicit ?? controller.animated) && !reduceMotion
        if animate {
            withAnimation(.easeInOut(duration: 0.6)) { pose.glasses = target }
        } else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { pose.glasses = target }
        }
    }

    private func applyHead() {
        // No head following with Reduce Motion: stay neutral.
        let target = reduceMotion ? MascotPose(glasses: pose.glasses) : MascotPose(
            glasses: pose.glasses, pitch: controller.pitch, roll: controller.roll, yaw: controller.yaw)
        guard target != pose else { return }
        if reduceMotion {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { pose = target }
        } else {
            let seconds = min(max(controller.animationDuration, 0.1), 2)
            withAnimation(.easeInOut(duration: seconds)) {
                pose.pitch = target.pitch
                pose.roll = target.roll
                pose.yaw = target.yaw
            }
        }
    }
}
