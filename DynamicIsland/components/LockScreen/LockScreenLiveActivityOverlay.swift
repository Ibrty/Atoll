import SwiftUI
import Defaults

final class LockScreenLiveActivityOverlayModel: ObservableObject {
    @Published var scale: CGFloat = 0.6
    @Published var opacity: Double = 0
}

struct LockScreenLiveActivityOverlay: View {
    @ObservedObject var model: LockScreenLiveActivityOverlayModel
    @ObservedObject var animator: LockIconAnimator
    @ObservedObject private var focusManager = DoNotDisturbManager.shared
    let notchSize: CGSize

    @Default(.lockScreenShowFocusIconInLiveActivity) private var lockScreenShowFocusIconInLiveActivity
    @Default(.enableDoNotDisturbDetection) private var focusDetectionEnabled
    @Default(.lockScreenColoredFocusIconInLiveActivity) private var lockScreenColoredFocusIconInLiveActivity

    private var indicatorSize: CGFloat {
        max(0, notchSize.height - 12)
    }

    private var shouldShowFocusIcon: Bool {
        lockScreenShowFocusIconInLiveActivity &&
        focusDetectionEnabled &&
        focusManager.isDoNotDisturbActive
    }

    private var focusMode: FocusModeType {
        FocusModeType.resolve(
            identifier: focusManager.currentFocusModeIdentifier,
            name: focusManager.currentFocusModeName
        )
    }

    private var focusIcon: Image {
        focusMode
            .resolvedActiveIcon(usePrivateSymbol: true)
            .renderingMode(.template)
    }

    private var focusIconColor: Color {
        // When disabled, render in white for a clean, monochrome look.
        // When enabled, use Atoll’s per-focus accent color (same source as DoNotDisturbLiveActivity).
        lockScreenColoredFocusIconInLiveActivity ? focusMode.accentColor : .white
    }

    private var focusIconView: some View {
        focusIcon
            .font(.system(size: max(14, indicatorSize * 0.78), weight: .semibold))
            .frame(width: indicatorSize, height: indicatorSize)
            .foregroundStyle(focusIconColor)
            .accessibilityLabel("Focus")
    }

    private var horizontalPadding: CGFloat {
        cornerRadiusInsets.closed.bottom
    }

    private var totalWidth: CGFloat {
        notchSize.width + (indicatorSize * 2) + (horizontalPadding * 2)
    }

    private var collapsedScale: CGFloat {
        Self.collapsedScale(for: notchSize)
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .overlay(alignment: .leading) {
                    LockIconProgressView(progress: animator.progress)
                        .frame(width: indicatorSize, height: indicatorSize)
                }
                .frame(width: indicatorSize, height: notchSize.height)

            Rectangle()
                .fill(.black)
                .frame(width: notchSize.width, height: notchSize.height)

            Color.clear
                .overlay(alignment: .trailing) {
                    if shouldShowFocusIcon {
                        focusIconView
                    }
                }
                .frame(width: indicatorSize, height: notchSize.height)
        }
        .frame(width: notchSize.width + (indicatorSize * 2), height: notchSize.height)
        .padding(.horizontal, horizontalPadding)
        .background(Color.black)
        .clipShape(
            NotchShape(
                topCornerRadius: cornerRadiusInsets.closed.top,
                bottomCornerRadius: cornerRadiusInsets.closed.bottom
            )
        )
        .frame(width: totalWidth, height: notchSize.height)
        .scaleEffect(x: max(model.scale, collapsedScale), y: 1, anchor: .center)
        .opacity(model.opacity)
    }
}

extension LockScreenLiveActivityOverlay {
    static func collapsedScale(for notchSize: CGSize) -> CGFloat {
        let indicatorSize = max(0, notchSize.height - 12)
        let horizontalPadding = cornerRadiusInsets.closed.bottom
        let totalWidth = notchSize.width + (indicatorSize * 2) + (horizontalPadding * 2)
        guard totalWidth > 0 else { return 1 }
        return notchSize.width / totalWidth
    }
}
