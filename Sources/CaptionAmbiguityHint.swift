import SwiftUI

/// A reading aid for an actual model marker, never a correctness score.
struct CaptionAmbiguityHint: View {
    var chinese: String
    var french: String
    @AppStorage(CaptionAmbiguity.visibilityKey) private var showHints = true
    @State private var showingDetails = false

    var body: some View {
        if showHints && CaptionAmbiguity.hasMarker(chinese) {
            Button { showingDetails = true } label: {
                Label("有歧义", systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04), in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("显示这段译文的歧义说明")
            .popover(isPresented: $showingDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("这一段可能有歧义").font(.headline)
                    Text(french).font(.callout).foregroundStyle(.secondary).lineLimit(5)
                    Text("译文被标记为存疑。可在课后结合法语原文回看；如已保存录音，也可回听。")
                        .font(.callout)
                    HStack {
                        Button("隐藏歧义提示") { showingDetails = false; showHints = false }
                        Spacer()
                        Button("收起") { showingDetails = false }
                    }.font(.callout)
                }
                .padding(20).frame(width: 310)
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}
