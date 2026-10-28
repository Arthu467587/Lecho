import SwiftUI

struct CaptionFontControl: View {
    @Binding var size: Double
    private var current: Double { CaptionAppearance.normalized(size) }
    var body: some View {
        HStack(spacing: 4) {
            Button { size = CaptionAppearance.adjusted(size, by: -1) } label: {
                Text("A−").frame(minWidth: 40, minHeight: 40)
            }.disabled(current == CaptionAppearance.sizes.first).accessibilityLabel("缩小字幕字号")
            Menu {
                Picker("字幕字号", selection: $size) {
                    ForEach(CaptionAppearance.sizes, id: \.self) { value in
                        Text("\(Int(value)) 点" + (value == CaptionAppearance.defaultSize ? "（默认）" : "")).tag(value)
                    }
                }
                Button("恢复默认字号") { size = CaptionAppearance.defaultSize }
            } label: {
                Text("\(Int(current)) pt").monospacedDigit().frame(minWidth: 52, minHeight: 40)
            }.accessibilityLabel("字幕字号，当前\(Int(current))点")
            Button { size = CaptionAppearance.adjusted(size, by: 1) } label: {
                Text("A+").frame(minWidth: 40, minHeight: 40)
            }.disabled(current == CaptionAppearance.sizes.last).accessibilityLabel("放大字幕字号")
        }.buttonStyle(.borderless)
            .fixedSize(horizontal: true, vertical: false)
    }
}
