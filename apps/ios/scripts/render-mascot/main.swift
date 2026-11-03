// Renders preview PNGs of Lotti's raccoon mascot (apps/ios/Lotti/Mascot/Art) on macOS without Xcode.
// Built and run by render.sh; see README.md.
import AppKit
import SwiftUI

struct Pose {
    var name: String
    var pitch: Double = 0
    var roll: Double = 0
    var yaw: Double = 0
}

let poses: [Pose] = [
    Pose(name: "neutral"),
    Pose(name: "pitch+15", pitch: 15),
    Pose(name: "pitch-15", pitch: -15),
    Pose(name: "pitch+20", pitch: 20),
    Pose(name: "pitch-20", pitch: -20),
    Pose(name: "roll+12", roll: 12),
    Pose(name: "roll-12", roll: -12),
    Pose(name: "roll+15", roll: 15),
    Pose(name: "roll-15", roll: -15),
    Pose(name: "yaw+20", yaw: 20),
    Pose(name: "yaw-20", yaw: -20),
]
let progresses: [Double] = [0, 0.5, 1]
let motionSteps: [Double] = [0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.85, 0.92, 1]

enum Scheme: String, CaseIterable {
    case light, dark
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
    var background: Color { self == .light ? .white : Color(red: 0.0, green: 0.0, blue: 0.0) }
    var ink: Color { self == .light ? .black : .white }
}

func progressName(_ p: Double) -> String { p == 0.5 ? "0.5" : String(Int(p)) }

@MainActor
func writePNG<V: View>(_ view: V, size: CGSize?, scale: CGFloat, to url: URL) {
    let renderer = ImageRenderer(content: view.frame(width: size?.width, height: size?.height).fixedSize())
    renderer.scale = scale
    guard let image = renderer.cgImage else {
        FileHandle.standardError.write("render failed: \(url.lastPathComponent)\n".data(using: .utf8)!)
        return
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    do { try data.write(to: url) } catch { print("write failed: \(error)") }
    print("\(url.lastPathComponent)  \(image.width)×\(image.height)")
}

func onBackground<V: View>(_ scheme: Scheme, _ view: V) -> some View {
    view
        .background(scheme.background)
        .environment(\.colorScheme, scheme.colorScheme)
}

// MARK: - Contact sheet

struct Tile<Content: View>: View {
    var label: String
    var scheme: Scheme
    var side: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 4) {
            content.frame(width: side, height: side)
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(scheme.ink.opacity(0.7))
        }
        .padding(6)
        .background(scheme.background)
        .environment(\.colorScheme, scheme.colorScheme)
    }
}

struct SheetSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
            content
        }
    }
}

struct HeaderMock: View {
    var scheme: Scheme
    var progress: Double
    var body: some View {
        HStack(spacing: 8) {
            RaccoonAvatar(glassesProgress: progress).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Lotti").font(.system(size: 15, weight: .semibold)).foregroundStyle(scheme.ink)
                Text("online").font(.system(size: 11)).foregroundStyle(scheme.ink.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 180, height: 52)
        .background(scheme == .light ? Color(white: 0.97) : Color(red: 0.11, green: 0.11, blue: 0.12))
        .environment(\.colorScheme, scheme.colorScheme)
    }
}

struct ContactSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Lotti raccoon — preview sheet").font(.system(size: 20, weight: .bold)).foregroundStyle(.black)

            SheetSection(title: "Glasses progress 0 / 0.5 / 1 (large, 200 pt here)") {
                HStack(spacing: 0) {
                    ForEach(Scheme.allCases, id: \.self) { scheme in
                        ForEach(progresses, id: \.self) { p in
                            Tile(label: "\(scheme.rawValue) g=\(progressName(p))", scheme: scheme, side: 200) {
                                RaccoonView(glassesProgress: p)
                            }
                        }
                    }
                }
            }

            SheetSection(title: "Glasses motion strip: progress 0 → 1 (light, then dark with yaw +15 / roll -8)") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(motionSteps, id: \.self) { p in
                            Tile(label: "g=\(String(format: "%.2g", p))", scheme: .light, side: 140) {
                                RaccoonView(glassesProgress: p)
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(motionSteps, id: \.self) { p in
                            Tile(label: "g=\(String(format: "%.2g", p))", scheme: .dark, side: 140) {
                                RaccoonView(glassesProgress: p, headRoll: -8, headYaw: 15)
                            }
                        }
                    }
                }
            }

            ForEach(Scheme.allCases, id: \.self) { scheme in
                SheetSection(title: "Head poses, glasses on (\(scheme.rawValue))") {
                    HStack(spacing: 0) {
                        ForEach(poses, id: \.name) { pose in
                            Tile(label: pose.name, scheme: scheme, side: 150) {
                                RaccoonView(glassesProgress: 1, headPitch: pose.pitch, headRoll: pose.roll, headYaw: pose.yaw)
                            }
                        }
                    }
                }
            }

            SheetSection(title: "Head poses, glasses off (light / dark)") {
                HStack(spacing: 0) {
                    ForEach([Pose(name: "pitch-20", pitch: -20), Pose(name: "roll+15", roll: 15), Pose(name: "pitch+20", pitch: 20)], id: \.name) { pose in
                        ForEach(Scheme.allCases, id: \.self) { scheme in
                            Tile(label: "\(scheme.rawValue) \(pose.name)", scheme: scheme, side: 168) {
                                RaccoonView(glassesProgress: 0, headPitch: pose.pitch, headRoll: pose.roll, headYaw: pose.yaw)
                            }
                        }
                    }
                }
            }

            SheetSection(title: "Avatars at real size: 28 / 36 / 64 pt, and full body at 36 / 64 pt") {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Scheme.allCases, id: \.self) { scheme in
                        ForEach(progresses, id: \.self) { p in
                            VStack(spacing: 4) {
                                HStack(alignment: .bottom, spacing: 6) {
                                    RaccoonAvatar(glassesProgress: p).frame(width: 28, height: 28)
                                    RaccoonAvatar(glassesProgress: p).frame(width: 36, height: 36)
                                    RaccoonAvatar(glassesProgress: p).frame(width: 64, height: 64)
                                }
                                HStack(alignment: .bottom, spacing: 6) {
                                    RaccoonView(glassesProgress: p).frame(width: 36, height: 36)
                                    RaccoonView(glassesProgress: p).frame(width: 64, height: 64)
                                }
                                Text("\(scheme.rawValue) g=\(progressName(p))").font(.system(size: 11, design: .monospaced)).foregroundStyle(scheme.ink.opacity(0.7))
                            }
                            .padding(8)
                            .background(scheme.background)
                            .environment(\.colorScheme, scheme.colorScheme)
                        }
                    }
                }
            }

            SheetSection(title: "Avatar poses at 64 pt and 36 pt (light / dark)") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Scheme.allCases, id: \.self) { scheme in
                        HStack(spacing: 0) {
                            ForEach(poses, id: \.name) { pose in
                                VStack(spacing: 4) {
                                    HStack(alignment: .bottom, spacing: 6) {
                                        RaccoonAvatar(glassesProgress: 1, headPitch: pose.pitch, headRoll: pose.roll, headYaw: pose.yaw).frame(width: 64, height: 64)
                                        RaccoonAvatar(glassesProgress: 1, headPitch: pose.pitch, headRoll: pose.roll, headYaw: pose.yaw).frame(width: 36, height: 36)
                                    }
                                    Text(pose.name).font(.system(size: 10, design: .monospaced)).foregroundStyle(scheme.ink.opacity(0.7))
                                }
                                .padding(8)
                                .background(scheme.background)
                                .environment(\.colorScheme, scheme.colorScheme)
                            }
                        }
                    }
                }
            }

            SheetSection(title: "Chat header mock (36 pt avatar)") {
                HStack(spacing: 12) {
                    ForEach(Scheme.allCases, id: \.self) { scheme in
                        HeaderMock(scheme: scheme, progress: 1)
                        HeaderMock(scheme: scheme, progress: 0)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(white: 0.86))
    }
}

// MARK: - Main

@main
struct RenderMascot {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: render-mascot <output-dir>")
            exit(2)
        }
        let out = URL(fileURLWithPath: args[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func file(_ name: String) -> URL { out.appendingPathComponent(name + ".png") }

        for scheme in Scheme.allCases {
            // Large (300 pt @2x = 600 px): glasses progress, neutral head.
            for p in progresses {
                writePNG(onBackground(scheme, RaccoonView(glassesProgress: p)),
                         size: CGSize(width: 300, height: 300), scale: 2,
                         to: file("large-\(scheme.rawValue)-glasses-\(progressName(p))"))
            }
            // Large head poses with glasses on.
            for pose in poses where pose.name != "neutral" {
                writePNG(onBackground(scheme, RaccoonView(glassesProgress: 1, headPitch: pose.pitch, headRoll: pose.roll, headYaw: pose.yaw)),
                         size: CGSize(width: 300, height: 300), scale: 2,
                         to: file("large-\(scheme.rawValue)-pose-\(pose.name)"))
            }
            // Small avatars: 36 pt @3x = 108 px and 64 px.
            for p in progresses {
                writePNG(onBackground(scheme, RaccoonAvatar(glassesProgress: p)),
                         size: CGSize(width: 36, height: 36), scale: 3,
                         to: file("avatar108-\(scheme.rawValue)-glasses-\(progressName(p))"))
                writePNG(onBackground(scheme, RaccoonAvatar(glassesProgress: p)),
                         size: CGSize(width: 64, height: 64), scale: 1,
                         to: file("avatar64-\(scheme.rawValue)-glasses-\(progressName(p))"))
            }
            for pose in poses where pose.name != "neutral" {
                writePNG(onBackground(scheme, RaccoonAvatar(glassesProgress: 1, headPitch: pose.pitch, headRoll: pose.roll, headYaw: pose.yaw)),
                         size: CGSize(width: 36, height: 36), scale: 3,
                         to: file("avatar108-\(scheme.rawValue)-pose-\(pose.name)"))
            }
            // Full body small.
            writePNG(onBackground(scheme, RaccoonView(glassesProgress: 1)),
                     size: CGSize(width: 36, height: 36), scale: 3,
                     to: file("body108-\(scheme.rawValue)-glasses-1"))
            writePNG(onBackground(scheme, RaccoonView(glassesProgress: 1)),
                     size: CGSize(width: 64, height: 64), scale: 1,
                     to: file("body64-\(scheme.rawValue)-glasses-1"))
        }

        writePNG(ContactSheet(), size: nil, scale: 2, to: file("contact-sheet"))
    }
}
