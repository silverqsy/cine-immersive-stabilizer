// SwiftUI content view — minimalist single-column layout modelled on the
// community ImmersiveStablizer build: no GroupBox bezels, bold section
// headings, and helper text under each control explaining what it does.

import SwiftUI
import AppKit

@MainActor
final class Model: ObservableObject {
    @Published var brawURL: URL? = nil
    @Published var settingText: String? = nil
    @Published var log: String = ""
    @Published var running: Bool = false
    @Published var status: String = ""

    @Published var smoothMs: Double = 1000
    @Published var maxCorrDeg: Double = 15
    @Published var responsiveness: Double = 1.0
    @Published var horizonLock: Bool = false
    @Published var yawOffset: Double = 0
    @Published var tiltOffset: Double = 0
    @Published var rollOffset: Double = 0

    func append(_ line: String) { log += line + "\n" }

    func stabilize() async {
        guard let url = brawURL else { return }
        running = true
        settingText = nil
        log = ""
        status = "Stabilizing \(url.lastPathComponent) …"
        defer { running = false }

        let settings = StabSettings(
            smoothMs: smoothMs, maxCorrDeg: maxCorrDeg,
            responsiveness: responsiveness, horizonLock: horizonLock,
            yawOffset: yawOffset, tiltOffset: tiltOffset, rollOffset: rollOffset)

        do {
            let collected = try await Task.detached(priority: .userInitiated) {
                () throws -> (result: StabResult, logLines: String) in
                var lines = ""
                let r = try Stabilizer.process(braw: url, settings: settings) { line in
                    lines += line + "\n"
                }
                return (r, lines)
            }.value
            log += collected.logLines
            settingText = PanoMapSetting.build(keyframes: collected.result.keyframes)
            status = "Ready — save or copy to clipboard."
            append("✅ PanoMap node ready.")
        } catch {
            append("❌ \(error.localizedDescription)")
            status = "Failed"
        }
    }

    func save() {
        guard let text = settingText, let braw = brawURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = braw.deletingPathExtension().lastPathComponent + ".setting"
        panel.allowedContentTypes = [.item]
        panel.title = "Save Fusion Setting"
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.lowercased() != "setting" {
                url = url.appendingPathExtension("setting")
            }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                append("💾 Saved → \(url.path)")
                status = "Saved: \(url.path)"
            } catch {
                append("❌ Save failed: \(error.localizedDescription)")
            }
        }
    }

    func copyToClipboard() {
        guard let text = settingText else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        append("📋 Copied to clipboard. In Fusion: Edit → Paste Settings.")
        status = "Copied to clipboard"
    }
}

// ── helpers ───────────────────────────────────────────────────────

/// Labelled numeric text field with a short explanation underneath.
private struct NumberField: View {
    let label: String
    let help: String?
    @Binding var value: Double
    var width: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 13, weight: .regular))
                Spacer()
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                    .multilineTextAlignment(.trailing)
            }
            if let help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .padding(.top, 8)
    }
}

// ── main view ─────────────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var m = Model()

    var body: some View {
        // ScrollView wraps the content so it still works if the window is
        // shrunk below the ideal size — but defaults are tuned large
        // enough that nothing scrolls on first launch.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                fileRow
                Divider()

                SectionHeader(title: "Stabilization settings")

                NumberField(
                    label: "Smoothing window (ms, 0 = camera lock)",
                    help: "0 = camera-lock (full stabilization). >0 = "
                        + "velocity-dampened smoothing.",
                    value: $m.smoothMs)

                NumberField(
                    label: "Max correction (°)",
                    help: "Soft cap on per-frame rotation. Beyond this, "
                        + "corrections are logarithmically clamped.",
                    value: $m.maxCorrDeg)

                NumberField(
                    label: "Responsiveness",
                    help: "How fast the smoother adapts to motion. 1.0 = default.",
                    value: $m.responsiveness)

                Toggle("Horizon lock", isOn: $m.horizonLock)
                    .toggleStyle(.checkbox)
                Text("De-roll so gravity stays vertical in the output.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                SectionHeader(title: "Global offset")

                HStack(spacing: 24) {
                    labelledSpin("Yaw", $m.yawOffset)
                    labelledSpin("Tilt", $m.tiltOffset)
                    labelledSpin("Roll", $m.rollOffset)
                    Spacer()
                }
                Text("Added to every keyframe after stabilization.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Divider()

                actionRow

                SectionHeader(title: "Log")
                logView

                footer
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labelledSpin(_ label: String, _ binding: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text("\(label) (°)").font(.system(size: 13))
            TextField("", value: binding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - rows

    private var fileRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.brawURL?.lastPathComponent ?? "No BRAW loaded")
                    .font(.system(size: 14, weight: .semibold))
                Text(m.brawURL.map { $0.path } ?? "Click Open BRAW to choose a clip")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Open BRAW…") { openBraw() }.disabled(m.running)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await m.stabilize() }
            } label: {
                Text("Stabilize").frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .disabled(m.brawURL == nil || m.running)

            Button("Save .setting…") { m.save() }
                .disabled(m.settingText == nil || m.running)
            Button("Copy to clipboard") { m.copyToClipboard() }
                .disabled(m.settingText == nil || m.running)

            if m.running { ProgressView().controlSize(.small) }
            Spacer()
            Text(m.status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var logView: some View {
        ScrollView {
            Text(m.log.isEmpty ? "—" : m.log)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(minHeight: 110, maxHeight: 160)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            Text("""
            1. Create a timeline in DaVinci with the BRAW — don't trim yet.
            2. Load the same BRAW in this app and click Stabilize.
            3. Paste the node into the Fusion tab — one for each eye.
            4. Trim the clip afterwards if needed.
            """)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Shameless Plug: Want to shoot VR180 without hauling a Cine Immersive? Check out my modded compact VR180 cameras!")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - open panel

    private func openBraw() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.title = "Open BRAW"
        if panel.runModal() == .OK, let url = panel.url {
            m.brawURL = url
            m.settingText = nil
            m.log = ""
            m.append("Loaded: \(url.path)")
        }
    }
}

#Preview { ContentView() }
