//
//  InlineHUDs.swift
//  DynamicIsland
//
//  Created by Richard Kunkli on 14/09/2024.
//

import SwiftUI
import AppKit
import AVFoundation
import Defaults

// MARK: - Inline HUD looping .mov icon

private final class LoopingPlayerController {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        self.player = AVQueuePlayer()
        self.player.isMuted = true
        self.player.actionAtItemEnd = .none
        self.looper = AVPlayerLooper(player: self.player, templateItem: item)
        self.player.play()
    }

    deinit {
        player.pause()
        looper = nil
    }
}

private struct LoopingVideoIcon: NSViewRepresentable {
    let url: URL
    let size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true

        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds

        view.layer?.addSublayer(layer)

        context.coordinator.attach(layer: layer, url: url)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op; the animation loops via AVPlayerLooper.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var controller: LoopingPlayerController?

        func attach(layer: AVPlayerLayer, url: URL) {
            controller = LoopingPlayerController(url: url)
            layer.player = controller?.player
        }
    }
}


struct InlineHUD: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    @Binding var hoverAnimation: Bool
    @Binding var gestureProgress: CGFloat
    
    @Default(.useColorCodedBatteryDisplay) var useColorCodedBatteryDisplay
    @Default(.useColorCodedVolumeDisplay) var useColorCodedVolumeDisplay
    @Default(.useSmoothColorGradient) var useSmoothColorGradient
    @Default(.progressBarStyle) var progressBarStyle
    @Default(.showProgressPercentages) var showProgressPercentages
    @Default(.useCircularBluetoothBatteryIndicator) var useCircularBluetoothBatteryIndicator
    @Default(.showBluetoothBatteryPercentageText) var showBluetoothBatteryPercentageText
    @Default(.showBluetoothDeviceNameMarquee) var showBluetoothDeviceNameMarquee
    @Default(.enableMinimalisticUI) var enableMinimalisticUI
    @ObservedObject var bluetoothManager = BluetoothAudioManager.shared
    
    @State private var displayName: String = ""
    
    var body: some View {
        let useCircularIndicator = useCircularBluetoothBatteryIndicator
        let hasBatteryLevel = value > 0
        let leftIconWidth: CGFloat = 20
        let leftIconToTextSpacing: CGFloat = 5

        // Dynamically size the left/info area for Bluetooth device names so they don't get cut off.
        // When marquee is enabled, we use the measured text width to compute a natural container width.
        let baseInfoWidth: CGFloat = {
            guard type == .bluetoothAudio else { return 100 }

            // If we are showing the device name (marquee toggle), allow the container to expand to fit it.
            if showBluetoothDeviceNameMarquee {
                let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
                let measuredNameWidth = measureTextWidth(displayName, font: nameFont)

                // Icon + spacing + name + breathing room + small safety buffer to avoid accidental marquee.
                let padding: CGFloat = enableMinimalisticUI ? 12 : 16
                let safetyBuffer: CGFloat = 10
                return leftIconWidth + leftIconToTextSpacing + measuredNameWidth + padding + safetyBuffer
            }

            // Original compact widths when we are NOT showing the device name.
            return enableMinimalisticUI ? 64 : 72
        }()

        let infoWidth: CGFloat = {
            var width = baseInfoWidth + gestureProgress / 2
            if !hoverAnimation { width -= 8 }

            // Preserve the old minimum widths so the HUD doesn't collapse too much.
            let minimum: CGFloat = {
                guard type == .bluetoothAudio else { return 88 }
                if showBluetoothDeviceNameMarquee {
                    return enableMinimalisticUI ? 112 : 120
                }
                return enableMinimalisticUI ? 56 : 68
            }()

            return max(width, minimum)
        }()

        let baseTrailingWidth: CGFloat = {
            guard type == .bluetoothAudio else { return 100 }
            if !hasBatteryLevel {
                return showBluetoothDeviceNameMarquee ? (enableMinimalisticUI ? 104 : 118) : (enableMinimalisticUI ? 74 : 88)
            }

            if useCircularIndicator {
                return showBluetoothBatteryPercentageText ? (enableMinimalisticUI ? 108 : 120) : (enableMinimalisticUI ? 72 : 84)
            }

            return showBluetoothBatteryPercentageText ? (enableMinimalisticUI ? 118 : 136) : (enableMinimalisticUI ? 92 : 108)
        }()

        let trailingWidth: CGFloat = {
            // For Bluetooth battery display (linear OR circular), keep both wings balanced so
            // the indicator always has a consistent distance from the popup's right edge.
            if type == .bluetoothAudio, hasBatteryLevel {
                return infoWidth
            }

            var width = baseTrailingWidth + gestureProgress / 2
            if !hoverAnimation { width -= 8 }
            let minimum: CGFloat = {
                guard type == .bluetoothAudio else { return 90 }
                if !hasBatteryLevel {
                    return showBluetoothDeviceNameMarquee ? (enableMinimalisticUI ? 96 : 110) : (enableMinimalisticUI ? 62 : 88)
                }

                if useCircularIndicator {
                    return showBluetoothBatteryPercentageText ? (enableMinimalisticUI ? 92 : 110) : (enableMinimalisticUI ? 56 : 72)
                }

                return showBluetoothBatteryPercentageText ? (enableMinimalisticUI ? 104 : 120) : (enableMinimalisticUI ? 72 : 90)
            }()
            return max(width, minimum)
        }()

        let totalHUDWidth: CGFloat = {
            // For Bluetooth notifications we intentionally size the overall HUD as:
            // (2 * left wing width) + notch width, so both wings have equal space around the notch.
            if type == .bluetoothAudio {
                return (2 * infoWidth) + vm.closedNotchSize.width
            }

            // For other HUD types, fall back to the natural combined width.
            return infoWidth + trailingWidth + vm.closedNotchSize.width
        }()

        let wingHeight: CGFloat = vm.closedNotchSize.height - (hoverAnimation ? 0 : 12)
        let outerHeight: CGFloat = vm.closedNotchSize.height + (hoverAnimation ? 8 : 0)
        let centerX: CGFloat = totalHUDWidth / 2
        let centerY: CGFloat = outerHeight / 2

        return ZStack {
            // Center notch spacer (visual + layout reference)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width, height: wingHeight)
                .position(x: centerX, y: centerY)

            // LEFT WING: anchored so its trailing edge sits at the left edge of the notch
            HStack(spacing: leftIconToTextSpacing) {
                Group {
                    switch (type) {
                        case .volume:
                            if icon.isEmpty {
                                // Show headphone icon if Bluetooth audio is connected, otherwise speaker
                                let baseIcon = bluetoothManager.isBluetoothAudioConnected ? "headphones" : SpeakerSymbol(value)
                                Image(systemName: baseIcon)
                                    .contentTransition(.interpolate)
                                    .symbolVariant(value > 0 ? .none : .slash)
                                    .frame(width: 20, height: 15, alignment: .leading)
                            } else {
                                Image(systemName: icon)
                                    .contentTransition(.interpolate)
                                    .opacity(value.isZero ? 0.6 : 1)
                                    .scaleEffect(value.isZero ? 0.85 : 1)
                                    .frame(width: 20, height: 15, alignment: .leading)
                            }
                        case .brightness:
                            Image(systemName: BrightnessSymbol(value))
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .backlight:
                            Image(systemName: BacklightSymbol(value))
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .mic:
                            Image(systemName: "mic")
                                .symbolRenderingMode(.hierarchical)
                                .symbolVariant(value > 0 ? .none : .slash)
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .timer:
                            Image(systemName: "timer")
                                .symbolRenderingMode(.hierarchical)
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .bluetoothAudio:
                            if let deviceType = bluetoothManager.lastConnectedDevice?.deviceType,
                               let url = Bundle.main.url(forResource: deviceType.inlineHUDAnimationBaseName, withExtension: "mov") {
                                LoopingVideoIcon(url: url, size: CGSize(width: 20, height: 20))
                                    .frame(width: 20, height: 20, alignment: .center)
                            } else {
                                Image(systemName: icon.isEmpty ? "bluetooth" : icon)
                                    .symbolRenderingMode(.hierarchical)
                                    .contentTransition(.interpolate)
                                    .frame(width: 20, height: 15, alignment: .center)
                            }
                        default:
                            EmptyView()
                    }
                }
                .foregroundStyle(.white)
                .symbolVariant(.fill)

                // Use marquee text for device names to handle long names
                if type == .bluetoothAudio {
                    if showBluetoothDeviceNameMarquee {
                        let marqueeWidth = max(60, infoWidth - leftIconWidth - leftIconToTextSpacing)
                        let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
                        let measuredNameWidth = measureTextWidth(displayName, font: nameFont)

                        if measuredNameWidth <= marqueeWidth {
                            Text(displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .allowsTightening(true)
                                .frame(width: marqueeWidth, alignment: .leading)
                        } else {
                            MarqueeText(
                                $displayName,
                                font: .system(size: 13, weight: .medium),
                                nsFont: .body,
                                textColor: .white,
                                minDuration: 0.2,
                                frameWidth: marqueeWidth
                            )
                            .frame(width: marqueeWidth, alignment: .leading)
                            .clipped()
                        }
                    }
                } else {
                    Text(Type2Name(type))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                }
            }
            .frame(width: infoWidth, height: wingHeight, alignment: .leading)
            .position(
                x: centerX - (vm.closedNotchSize.width / 2) - (infoWidth / 2),
                y: centerY
            )

            // RIGHT WING: anchored so its leading edge sits at the right edge of the notch
            HStack {
                if (type == .mic) {
                    Text(value.isZero ? "muted" : "unmuted")
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.interpolate)
                } else if (type == .timer) {
                    Text(TimerManager.shared.formattedRemainingTime())
                        .foregroundStyle(TimerManager.shared.timerColor)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.interpolate)
                } else if (type == .bluetoothAudio) {
                    if hasBatteryLevel {
                        let indicatorSpacing: CGFloat = {
                            if useCircularIndicator {
                                return showBluetoothBatteryPercentageText ? 8 : 2
                            }
                            return showBluetoothBatteryPercentageText ? 6 : 4
                        }()

                        HStack(spacing: indicatorSpacing) {
                            if useCircularIndicator {
                                // Keep circular HUD behavior unchanged.
                                CircularBatteryIndicator(
                                    value: value,
                                    useColorCoding: useColorCodedBatteryDisplay && progressBarStyle != .segmented,
                                    smoothGradient: useSmoothColorGradient
                                )
                                .allowsHitTesting(false)
                            } else {
                                // Make the linear battery track expand/contract to fill the right wing.
                                let percentString = "\(Int(value * 100))%"
                                let percentFont = NSFont.systemFont(ofSize: 12, weight: .medium)
                                let percentWidth: CGFloat = showBluetoothBatteryPercentageText
                                    ? measureTextWidth(percentString, font: percentFont)
                                    : 0

                                // Available space for the linear track inside the trailing wing.
                                // Subtract percentage text width and spacing when the percentage is visible.
                                let reservedSpacing: CGFloat = showBluetoothBatteryPercentageText ? indicatorSpacing : 0
                                let horizontalBreathingRoom: CGFloat = 10
                                let availableTrackWidth = max(
                                    28,
                                    trailingWidth - percentWidth - reservedSpacing - horizontalBreathingRoom
                                )

                                LinearBatteryIndicator(
                                    value: value,
                                    useColorCoding: useColorCodedBatteryDisplay && progressBarStyle != .segmented,
                                    smoothGradient: useSmoothColorGradient,
                                    trackWidth: availableTrackWidth
                                )
                                .allowsHitTesting(false)
                            }

                            if showBluetoothBatteryPercentageText {
                                Text("\(Int(value * 100))%")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    // Volume and brightness displays
                    Group {
                        if type == .volume {
                            Group {
                                if value.isZero {
                                    Text("muted")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.gray)
                                        .lineLimit(1)
                                        .allowsTightening(true)
                                        .multilineTextAlignment(.trailing)
                                        .contentTransition(.numericText())
                                } else {
                                    HStack(spacing: 6) {
                                        DraggableProgressBar(value: $value, colorMode: .volume)
                                        PercentageLabel(value: value, isVisible: showProgressPercentages)
                                    }
                                    .transition(.opacity.combined(with: .scale))
                                }
                            }
                            .animation(.smooth(duration: 0.2), value: value.isZero)
                        } else {
                            HStack(spacing: 6) {
                                DraggableProgressBar(value: $value)
                                PercentageLabel(value: value, isVisible: showProgressPercentages)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.trailing, (type == .bluetoothAudio && hasBatteryLevel) ? 6 : (trailingWidth > 0 ? 4 : 0))
            .frame(width: trailingWidth, height: wingHeight, alignment: .center)
            .position(
                x: centerX + (vm.closedNotchSize.width / 2) + (trailingWidth / 2),
                y: centerY
            )
        }
        .frame(width: totalHUDWidth, height: outerHeight, alignment: .center)
        .onAppear {
            displayName = Type2Name(type)
        }
        .onChange(of: type) { _, _ in
            displayName = Type2Name(type)
        }
        .onChange(of: bluetoothManager.lastConnectedDevice?.name) { _, _ in
            displayName = Type2Name(type)
        }
        .onChange(of: bluetoothManager.lastConnectedDevice?.deviceType) { _, _ in
            displayName = Type2Name(type)
        }
    }
    
    private func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        // Measure using AppKit so we can size the left HUD area to fit the device name.
        // This avoids truncation when "show device name" is enabled.
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return (text as NSString).size(withAttributes: attributes).width.rounded(.up)
    }

    private struct CircularBatteryIndicator: View {
        let value: CGFloat
        let useColorCoding: Bool
        let smoothGradient: Bool

        private var clampedValue: CGFloat {
            min(max(value, 0), 1)
        }

        private var indicatorColor: Color {
            if useColorCoding {
                return ColorCodedProgressBar.paletteColor(for: clampedValue, mode: .battery, smoothGradient: smoothGradient)
            }
            return .white
        }

        var body: some View {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 2.6)

                Circle()
                    .trim(from: 0, to: max(clampedValue, 0.015))
                    .rotation(.degrees(-90))
                    .stroke(indicatorColor, style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            }
            .frame(width: 22, height: 22)
            .animation(.smooth(duration: 0.18), value: clampedValue)
        }
    }

    private struct LinearBatteryIndicator: View {
        let value: CGFloat
        let useColorCoding: Bool
        let smoothGradient: Bool
        let trackWidth: CGFloat

        private let trackHeight: CGFloat = 6

        init(
            value: CGFloat,
            useColorCoding: Bool,
            smoothGradient: Bool,
            trackWidth: CGFloat = 54
        ) {
            self.value = value
            self.useColorCoding = useColorCoding
            self.smoothGradient = smoothGradient
            self.trackWidth = trackWidth
        }

        private var clampedValue: CGFloat {
            min(max(value, 0), 1)
        }

        private var fillColor: Color {
            if useColorCoding {
                return ColorCodedProgressBar.paletteColor(for: clampedValue, mode: .battery, smoothGradient: smoothGradient)
            }
            return .white
        }

        var body: some View {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: trackWidth, height: trackHeight)

                Capsule()
                    .fill(fillColor)
                    .frame(width: trackWidth * clampedValue, height: trackHeight)
            }
            .frame(width: trackWidth, height: trackHeight)
            .animation(.smooth(duration: 0.18), value: clampedValue)
        }
    }

    func SpeakerSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0:
                return "speaker"
            case 0...0.3:
                return "speaker.wave.1"
            case 0.3...0.8:
                return "speaker.wave.2"
            case 0.8...1:
                return "speaker.wave.3"
            default:
                return "speaker.wave.2"
        }
    }
    
    func BrightnessSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0...0.6:
                return "sun.min"
            case 0.6...1:
                return "sun.max"
            default:
                return "sun.min"
        }
    }

    func BacklightSymbol(_ value: CGFloat) -> String {
        if value >= 0.5 {
            return "light.max"
        }
        return "light.min"
    }
    
    func Type2Name(_ type: SneakContentType) -> String {
        switch(type) {
            case .volume:
                return "Volume"
            case .brightness:
                return "Brightness"
            case .backlight:
                return "Backlight"
            case .mic:
                return "Mic"
            case .bluetoothAudio:
                return BluetoothAudioManager.shared.lastConnectedDevice?.name ?? "Bluetooth"
            default:
                return ""
        }
    }
}

#Preview {
    InlineHUD(type: .constant(.brightness), value: .constant(0.4), icon: .constant(""), hoverAnimation: .constant(false), gestureProgress: .constant(0))
        .padding(.horizontal, 8)
        .background(Color.black)
        .padding()
        .environmentObject(DynamicIslandViewModel())
}
