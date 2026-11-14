import SwiftUI
import AppKit
import Combine

struct CurrentTranslation: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("現在の翻訳", systemImage: "captions.bubble.fill").font(.caption).foregroundStyle(Color.accentColor)
                Spacer()
                Text((!model.partial.isEmpty || model.pendingCount > 0 || model.bufferingEnglish) ? "…" : " ")
                    .font(.title3).accessibilityLabel((!model.partial.isEmpty || model.pendingCount > 0 || model.bufferingEnglish) ? "次の翻訳を処理中" : "")
            }
            ScrollView {
                Text(model.timelineLines.last(where: { $0.japanese != nil })?.japanese ?? "翻訳を開始すると、ここに日本語が表示されます。")
                    .font(.system(size: 18, weight: .medium)).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .topLeading).textSelection(.enabled)
            }.id(model.timelineLines.last(where: { $0.japanese != nil })?.id)
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.accentColor.opacity(0.12))
    }
}
struct SlideSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsHeading(title: "スライド", subtitle: "翻訳したいスライド領域を選択できます。")
                HStack {
                    Button("Safariを選択") { model.chooseSystemTarget() }.disabled(model.running || model.busy || model.cropBusy)
                    Button(model.cropBusy ? "取得中…" : "範囲を選び直す") { model.captureCropPreview() }
                        .disabled(model.cropBusy || model.busy || !model.systemTargetSelected)
                }
                Text(model.cropStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let image = model.cropPreview {
                    CropPreview(model: model, image: image)
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
                        .overlay(Text("Safariを選び、範囲を選び直すとここでドラッグできます。").font(.callout).padding())
                        .frame(height: 250)
                }
                Toggle("スライド翻訳を有効にする", isOn: $model.ocrEnabled)
                    .onChange(of: model.ocrEnabled) { _, _ in model.resetSlides() }
                Text("静止画は保存しません。画面が安定してから翻訳し、音声の翻訳を優先します。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
final class CropState: ObservableObject {
    @Published var drag: CGRect?
}
struct CropPreview: View {
    @ObservedObject var model: AppModel
    let image: NSImage
    @StateObject private var state = CropState()
    private var region: CGRect {
        state.drag ?? CGRect(x: model.regionX, y: 1 - model.regionY - model.regionHeight, width: model.regionWidth, height: model.regionHeight)
    }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                Rectangle().fill(Color.accentColor.opacity(0.18))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: region.width * size.width, height: region.height * size.height)
                    .offset(x: region.minX * size.width, y: region.minY * size.height)
            }.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in state.drag = normalized(value, size: size) }
                .onEnded { value in
                    let rect = normalized(value, size: size)
                    model.applyCrop(rect); state.drag = nil
                })
            .accessibilityLabel("OCR範囲選択。画像の上でドラッグしてください")
        }.aspectRatio(image.size.width / max(1, image.size.height), contentMode: .fit)
            .clipped().overlay(Rectangle().stroke(Color.secondary.opacity(0.4)))
    }
    private func normalized(_ value: DragGesture.Value, size: CGSize) -> CGRect {
        let x1 = min(1, max(0, value.startLocation.x / max(1, size.width)))
        let y1 = min(1, max(0, value.startLocation.y / max(1, size.height)))
        let x2 = min(1, max(0, value.location.x / max(1, size.width)))
        let y2 = min(1, max(0, value.location.y / max(1, size.height)))
        return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }
}
