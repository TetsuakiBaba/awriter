import SwiftUI
import AppKit

struct TypographyPanel: View {
    @Binding var fontID: String
    @Binding var fontSize: Double
    @Binding var colorHex: String

    @AppStorage(AppearanceMode.defaultsKey) private var appearanceMode = AppearanceMode.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("フォント")
                VStack(spacing: 2) {
                    ForEach(FontOption.available) { option in
                        fontRow(option)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("文字サイズ")
                HStack(spacing: 10) {
                    Text("あ").font(.system(size: 11))
                    Slider(value: $fontSize, in: 12...36, step: 1)
                    Text("あ").font(.system(size: 20))
                    Text("\(Int(fontSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("文字色")
                HStack(spacing: 10) {
                    ForEach(TextInk.swatches) { swatch in
                        swatchButton(swatch)
                    }
                    Spacer()
                    ColorPicker("カスタム", selection: customColor, supportsOpacity: false)
                        .labelsHidden()
                        .help("カスタム")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("外観")
                Picker("", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: appearanceMode) { _, newValue in
                    AppearanceMode.apply(newValue)
                }
                Text("文字色が「自動」以外のときは、地の明暗に合う外観を選んでください。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func fontRow(_ option: FontOption) -> some View {
        let isSelected = option.id == fontID
        return Button {
            fontID = option.id
        } label: {
            HStack {
                Text(option.name)
                    .font(Font(option.font(ofSize: 14) as CTFont))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }

    private func swatchButton(_ swatch: TextInk.Swatch) -> some View {
        let isSelected = colorHex == swatch.id
        return Button {
            colorHex = swatch.id
        } label: {
            Circle()
                .fill(Color(nsColor: TextInk.nsColor(for: swatch.id)))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-4)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(swatch.name)
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: TextInk.nsColor(for: colorHex)) },
            set: { colorHex = NSColor($0).hexString }
        )
    }
}
