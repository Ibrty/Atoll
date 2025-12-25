//
//  LockIconAnimationView.swift
//  DynamicIsland
//
//  Shared animator and SwiftUI Lottie rendering for the lock/unlock sequence.
//

import SwiftUI
import Lottie

@MainActor
final class LockIconAnimator: ObservableObject {
    @Published private(set) var progress: CGFloat

    private var animationTask: Task<Void, Never>?
    private let animationDuration: TimeInterval = 0.35
    private let animationSteps: Int = 48

    init(initiallyLocked: Bool) {
        progress = initiallyLocked ? 1.0 : 0.0
    }

    deinit {
        animationTask?.cancel()
    }

    func update(isLocked: Bool, animated: Bool = true) {
        let target = isLocked ? 1.0 : 0.0
        let clampedTarget = max(0.0, min(1.0, target))

        if !animated {
            animationTask?.cancel()
            progress = clampedTarget
            return
        }

        guard abs(progress - clampedTarget) > 0.0005 else {
            progress = clampedTarget
            return
        }

        animationTask?.cancel()

        let startProgress = progress
        let delta = clampedTarget - startProgress
        let stepDuration = animationDuration / Double(animationSteps)
        let stepNanoseconds = UInt64(stepDuration * 1_000_000_000)

        animationTask = Task { [weak self] in
            guard let self else { return }

            for step in 0...animationSteps {
                if Task.isCancelled { return }

                if step > 0 {
                    try? await Task.sleep(nanoseconds: stepNanoseconds)
                }

                let fraction = Double(step) / Double(animationSteps)
                let eased = easeOutCubic(fraction)
                progress = startProgress + CGFloat(eased) * CGFloat(delta)
            }

            progress = clampedTarget
        }
    }

    private func easeOutCubic(_ t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        return 1.0 - pow(1.0 - clamped, 3)
    }
}

struct LockIconProgressView: View {
    var progress: CGFloat
    var iconColor: Color = .white

    var body: some View {
        if LockIconLottieView.isAvailable {
            Rectangle()
                .fill(iconColor)
                .mask {
                    LockIconLottieView(progress: 1 - progress)
                        .scaleEffect(1.12)
                }
        } else {
            Image(systemName: progress >= 0.5 ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
        }
    }
}

struct LockIconLottieView: View {
    var progress: CGFloat

    private static let animation: LottieAnimation? = {
        if let animation = LottieAnimation.named("Lock") {
            return animation
        } else {
            print("⚠️ [LockIconLottieView] Missing Lock.json animation – falling back to SF Symbols")
            return nil
        }
    }()

    static var isAvailable: Bool {
        animation != nil
    }

    var body: some View {
        Group {
            if let animation = Self.animation {
                LottieView(animation: animation)
                    .currentProgress(progress)
                    .configuration(.init(renderingEngine: .mainThread))
            } else {
                Color.clear
            }
        }
    }
}
