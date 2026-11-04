import SwiftUI

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            if let help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let ok: Bool
    let okText: String
    let badText: String

    var body: some View {
        Label(ok ? okText : badText, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.medium))
            .foregroundStyle(ok ? .green : .orange)
    }
}

struct ActionPicker: View {
    let trigger: Trigger
    @Binding var action: PointerAction

    var body: some View {
        Picker(selection: $action) {
            ForEach(PointerAction.groups, id: \.title) { group in
                if group.title.isEmpty {
                    ForEach(group.actions) { a in Label(a.displayName, systemImage: a.symbol).tag(a) }
                } else {
                    Section(group.title) {
                        ForEach(group.actions) { a in Label(a.displayName, systemImage: a.symbol).tag(a) }
                    }
                }
            }
        } label: {
            Text(trigger.displayName)
        }
    }
}

/// Head attitude visualizer: the dot moves with head rotation rate, the bar shows tilt.
struct HeadVisualizer: View {
    let live: LiveReadout
    let tiltThreshold: Double

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5))
                Path { p in
                    p.move(to: CGPoint(x: 80, y: 0)); p.addLine(to: CGPoint(x: 80, y: 160))
                    p.move(to: CGPoint(x: 0, y: 80)); p.addLine(to: CGPoint(x: 160, y: 80))
                }
                .stroke(.secondary.opacity(0.3), lineWidth: 1)
                Circle()
                    .fill(live.hasData ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 18)
                    .offset(x: clamp(-live.yawRate / 3), y: clamp(-live.pitchRate / 3))
                    .animation(.easeOut(duration: 0.1), value: live)
            }
            .frame(width: 160, height: 160)

            VStack(alignment: .leading, spacing: 6) {
                row("Turn (yaw)", live.yaw, unit: "°")
                row("Nod (pitch)", live.pitch, unit: "°")
                row("Tilt (roll)", live.relativeRoll, unit: "°")
                row("Turn speed", live.yawRate, unit: "°/s")
                row("Nod speed", live.pitchRate, unit: "°/s")
                Text(tiltText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .font(.callout.monospacedDigit())
        }
    }

    private var tiltText: String {
        guard live.hasData else { return "No motion data yet — put your AirPods in." }
        if live.relativeRoll >= tiltThreshold { return "Tilt detected: right" }
        if live.relativeRoll <= -tiltThreshold { return "Tilt detected: left" }
        return "Move your head to see the dot respond."
    }

    private func clamp(_ v: Double) -> Double { min(max(v, -70), 70) }

    private func row(_ title: String, _ value: Double, unit: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(live.hasData ? String(format: "%+.0f%@", value, unit) : "—")
        }
    }
}

import AirCursorCore

/// Live checklist of every link in the chain, with a copy button for bug reports.
struct DiagnosticsSection: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Section {
            ForEach(controller.diagnostics.rows, id: \.label) { row in
                HStack {
                    Image(systemName: row.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(row.ok ? .green : .orange)
                    Text(row.label)
                    Spacer()
                    Text(row.value).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.callout)
            }
            HStack {
                Button("Use AirPods for Mac sound") {
                    controller.routeAudioToHeadphonesIfNeeded(force: true)
                }
                Spacer()
                Button("Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.diagnostics.text, forType: .string)
                }
            }
        } header: {
            Text("Diagnostics")
        }
    }
}
