import SwiftUI

enum SettingsTab: Hashable { case script, appearance, controls }

struct SettingsView: View {
    typealias Tab = SettingsTab

    @ObservedObject var model: PrompterModel
    let movePrompter: () -> Void
    let turnOnPrompter: () -> Void

    var body: some View {
        TabView(selection: $model.settingsTab) {
            ScriptTab(model: model)
                .tabItem { Label("Script", systemImage: "text.alignleft") }
                .tag(Tab.script)
            AppearanceTab(settings: $model.settings)
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
                .tag(Tab.appearance)
            ControlsTab(
                settings: $model.settings,
                displayStatus: model.displayStatus,
                movePrompter: movePrompter,
                turnOnPrompter: turnOnPrompter
            )
            .tabItem { Label("Controls", systemImage: "keyboard") }
            .tag(Tab.controls)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 520)
    }
}

private struct ScriptTab: View {
    @ObservedObject var model: PrompterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste plain text, markdown or Notion bullets. List markers and formatting are removed; nesting is kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $model.scriptText)
                .font(.system(size: 13, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Replace with Clipboard") { model.pasteFromClipboard() }
                Button("Clear") { model.load("") }
                Spacer()
                Text("\(model.stopCount) lines")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct AppearanceTab: View {
    @Binding var settings: PrompterSettings

    var body: some View {
        Form {
            Section("Text") {
                SliderRow("Font size", value: $settings.fontSize, range: PrompterSettings.fontSizeRange, step: 2, format: "%.0f pt")
                SliderRow("Line spacing", value: $settings.lineSpacing, range: PrompterSettings.lineSpacingRange, step: 1, format: "%.0f pt")
                SliderRow("Gap between lines", value: $settings.itemSpacing, range: PrompterSettings.itemSpacingRange, step: 2, format: "%.0f pt")
                SliderRow("Side margins", value: $settings.sideMargin, range: PrompterSettings.sideMarginRange, step: 5, format: "%.0f pt")
                Picker("Alignment", selection: $settings.alignment) {
                    Text("Left").tag(PrompterSettings.Alignment.leading)
                    Text("Centre").tag(PrompterSettings.Alignment.center)
                }
                .pickerStyle(.segmented)
            }
            Section("Colours") {
                ColorRow("Text", hex: $settings.textColor)
                ColorRow("Background", hex: $settings.backgroundColor)
                ColorRow("Highlight", hex: $settings.highlightColor)
                SliderRow("Upcoming lines", value: $settings.upcomingOpacity, range: PrompterSettings.opacityRange, step: 0.05, format: "%.0f%%", scale: 100)
            }
            Section("Reading line") {
                SliderRow("Position from top", value: $settings.readingLine, range: PrompterSettings.readingLineRange, step: 0.05, format: "%.0f%%", scale: 100)
                Toggle("Show the reading-line marker", isOn: $settings.showReadingMarker)
                Toggle("Mirror horizontally (beam-splitter glass)", isOn: $settings.mirrorHorizontally)
            }
            Button("Reset Appearance") {
                let keep = settings
                settings = .defaults
                settings.scrollSpeed = keep.scrollSpeed
                settings.clickerKeysGlobal = keep.clickerKeysGlobal
                settings.globalShortcuts = keep.globalShortcuts
                settings.keepOnTop = keep.keepOnTop
                settings.followPrompter = keep.followPrompter
            }
        }
        .formStyle(.grouped)
    }
}

private struct ControlsTab: View {
    @Binding var settings: PrompterSettings
    let displayStatus: String
    let movePrompter: () -> Void
    let turnOnPrompter: () -> Void

    var body: some View {
        Form {
            Section("Auto-scroll") {
                SliderRow("Speed", value: $settings.scrollSpeed, range: PrompterSettings.scrollSpeedRange, step: 5, format: "%.0f pt/s")
                Text("P starts and pauses. [ and ] change speed. Clicking or stepping while scrolling jumps and keeps going.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Works from any app") {
                Toggle("Clicker keys: Page Down / Page Up", isOn: $settings.clickerKeysGlobal)
                Toggle("⌃⌥→ next, ⌃⌥← previous, ⌃⌥Space auto-scroll", isOn: $settings.globalShortcuts)
            }
            Section("When the prompter window is focused") {
                Text("Click, Space, →, ↓, Return or Page Down: next line\nRight-click, ←, ↑ or Page Up: previous line\nHome / End: first / last line. Scroll wheel: fine-tune\n⌘V: paste new notes. + / −: text size. M: mirror")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Window") {
                Toggle("Keep on top of other windows", isOn: $settings.keepOnTop)
                Toggle("Move to the Elgato Prompter when it is switched on", isOn: $settings.followPrompter)
                LabeledContent("Showing on", value: displayStatus)
                HStack {
                    Button("Move to Prompter Display", action: movePrompter)
                    Button("Turn On Elgato Prompter", action: turnOnPrompter)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var scale: Double = 1

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String, scale: Double = 1) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
        self.scale = scale
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                // Rounding in the binding instead of passing `step` avoids
                // AppKit drawing a tick mark for every step.
                Slider(value: Binding(
                    get: { value },
                    set: { value = ($0 / step).rounded() * step }
                ), in: range)
                Text(String(format: format, value * scale))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }
}

private struct ColorRow: View {
    let title: String
    @Binding var hex: String

    init(_ title: String, hex: Binding<String>) {
        self.title = title
        _hex = hex
    }

    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { Color(hex: hex) },
            set: { hex = $0.hexString }
        ), supportsOpacity: false)
    }
}
