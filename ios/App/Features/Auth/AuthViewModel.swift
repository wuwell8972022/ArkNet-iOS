import SwiftUI

/// 滑块验证码 — CaptchaData(masterImage/tileImage/tileX/tileY) + SlideCaptchaView
/// parity: the user drags the tile horizontally; the solved X is submitted as
/// captchaAnswer together with captchaId.
struct SlideCaptchaView: View {

    let captcha: CaptchaData
    /// Called with the user's final drag X (pixels) — the value submitted to
    /// the server as captchaAnswer (server validates against its own tileX).
    let onSuccess: (Int) -> Void
    let onFail: () -> Void

    @State private var dragX: CGFloat = 0

    private let tileSide: CGFloat = 44

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                if let master = image(fromBase64: captcha.masterImage) {
                    Image(uiImage: master)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if let tile = image(fromBase64: captcha.tileImage) {
                    Image(uiImage: tile)
                        .resizable()
                        .frame(width: tileSide, height: tileSide)
                        .offset(x: captcha.tileY > 0 ? CGFloat(captcha.tileX) : 0,
                                y: CGFloat(captcha.tileY))
                        .opacity(0.0) // hole position hint hidden; user guesses via gap
                }
                // Draggable tile chip
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.accent)
                    .frame(width: tileSide, height: tileSide)
                    .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8))
                    .offset(x: dragX, y: CGFloat(captcha.tileY))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragX = max(0, min(value.translation.width, maxDrag))
                            }
                            .onEnded { _ in
                                let dragged = Int(dragX)
                                let solved = abs(dragged - captcha.tileX) <= 12
                                if solved {
                                    onSuccess(dragged)
                                } else {
                                    withAnimation(.spring()) { dragX = 0 }
                                    onFail()
                                }
                            }
                    )
            }
            .frame(height: 180)

            Text("拖动滑块完成拼图验证")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .background(Theme.cardBackground())
    }

    private var maxDrag: CGFloat { 220 }

    private func image(fromBase64 base64: String) -> UIImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return UIImage(data: data)
    }
}
