import SwiftUI
import Defaults
import AppKit
import CoreGraphics


struct LockScreenWeatherWidget: View {
    let snapshot: LockScreenWeatherSnapshot
    @ObservedObject private var bluetoothManager = BluetoothAudioManager.shared
    @ObservedObject private var focusManager = DoNotDisturbManager.shared
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.enableDoNotDisturbDetection) private var focusDetectionEnabled
    @Default(.showDoNotDisturbIndicator) private var focusIndicatorEnabled
    @Default(.enableLockScreenFocusWidget) private var lockScreenFocusWidgetEnabled
    @Default(.lockScreenHideFocusLabel) private var lockScreenHideFocusLabel
    @Default(.lockScreenShowCalendarCountdown) private var lockScreenShowCalendarCountdown
    @Default(.lockScreenShowCalendarEvent) private var lockScreenShowCalendarEvent
    @Default(.lockScreenShowCalendarEventEntireDuration) private var lockScreenShowCalendarEventEntireDuration
    @Default(.lockScreenShowCalendarEventAfterStartWindow) private var lockScreenShowCalendarEventAfterStartWindow
    @Default(.lockScreenShowCalendarTimeRemaining) private var lockScreenShowCalendarTimeRemaining
    @Default(.lockScreenShowCalendarStartTimeAfterBegins) private var lockScreenShowCalendarStartTimeAfterBegins
    @Default(.lockScreenCalendarEventLookaheadWindow) private var lockScreenCalendarEventLookaheadWindow
    @Default(.lockScreenWeatherWidgetRowOrder) private var lockScreenWeatherWidgetRowOrder
    @Default(.lockScreenCalendarSelectionMode) private var lockScreenCalendarSelectionMode
    @Default(.lockScreenSelectedCalendarIDs) private var lockScreenSelectedCalendarIDs
    @Default(.lockScreenShowCalendarEventAfterStartEnabled) private var lockScreenShowCalendarEventAfterStartEnabled
    
    @State private var currentTime = Date()
    @State private var calendarRowVisible: Bool = false
    @State private var lastCalendarLine: String = ""
    @State private var calendarRowRenderToken: Int = 0
    @State private var widgetWidthRemeasureToken: Int = 0
    private var currentCalendarEventID: String {
        nextCalendarEvent?.id ?? "no_event"
    }
    
    // MARK: - Refresh
    /// Refreshes every 15 seconds (general refresh), and optionally also ticks exactly on minute boundaries
    /// *only when the screen is locked* and the calendar widget is enabled.
    private final class LockAwareTicker: ObservableObject {
        @Published var now: Date = Date()
        
        private var refreshTimer: Timer?
        private var minuteTimer: Timer?
        
        private var lockObserver: NSObjectProtocol?
        private var unlockObserver: NSObjectProtocol?
        
        private var isLocked: Bool = false
        private var minuteAlignedEnabled: Bool = false
        
        func start() {
            stop()
            installLockObservers()
            refreshLockStateFromSystem()
            startGeneralRefresh()
            fireNow()
            updateMinuteAlignedTimer()
        }
        
        func stop() {
            refreshTimer?.invalidate()
            refreshTimer = nil
            
            minuteTimer?.invalidate()
            minuteTimer = nil
            
            if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
            if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
            lockObserver = nil
            unlockObserver = nil
        }
        
        func fireNow() {
            now = Date()
        }
        
        /// Enable/disable the minute-aligned ticker (minute boundary ticks).
        /// It will only actually run when the screen is locked.
        func setMinuteAlignedEnabled(_ enabled: Bool) {
            minuteAlignedEnabled = enabled
            updateMinuteAlignedTimer()
        }
        
        private func startGeneralRefresh() {
            // General refresh every 15 seconds (replaces the old 5-second timer).
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
                self?.fireNow()
            }
            refreshTimer?.tolerance = 0
            if let refreshTimer {
                RunLoop.main.add(refreshTimer, forMode: .common)
            }
        }
        
        private func refreshLockStateFromSystem() {
            // When the widget appears while the Mac is already locked, we won't receive
            // a "screenIsLocked" notification. Probe the current session state so the
            // minute-aligned timer can start immediately.
            if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
                if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
                    isLocked = locked
                }
            }
        }

        private func installLockObservers() {
            lockObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isLocked = true
                self.fireNow()
                self.updateMinuteAlignedTimer()
            }

            unlockObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isLocked = false
                self.fireNow()
                self.updateMinuteAlignedTimer()
            }
        }
        
        private func updateMinuteAlignedTimer() {
            // Only keep the minute-aligned timer when locked AND enabled.
            let shouldRun = isLocked && minuteAlignedEnabled
            
            if !shouldRun {
                minuteTimer?.invalidate()
                minuteTimer = nil
                return
            }
            
            // If it's already running, keep it.
            if minuteTimer != nil {
                return
            }
            
            scheduleNextBoundaryAndRepeat()
        }
        
        private func scheduleNextBoundaryAndRepeat() {
            let current = Date()
            let cal = Calendar.current
            
            // Next minute boundary: truncate seconds and add 1 minute.
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: current)
            comps.second = 0
            let thisMinute = cal.date(from: comps) ?? current
            let nextMinute = cal.date(byAdding: .minute, value: 1, to: thisMinute) ?? current.addingTimeInterval(60)
            
            let initialDelay = max(0.0, nextMinute.timeIntervalSince(current))
            
            // One-shot until the boundary, then every 60 seconds.
            minuteTimer = Timer.scheduledTimer(withTimeInterval: initialDelay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.fireNow()
                
                self.minuteTimer?.invalidate()
                self.minuteTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                    self?.fireNow()
                }
                self.minuteTimer?.tolerance = 0
                if let minuteTimer {
                    RunLoop.main.add(minuteTimer, forMode: .common)
                }
            }
            minuteTimer?.tolerance = 0
            if let minuteTimer {
                RunLoop.main.add(minuteTimer, forMode: .common)
            }
        }
        
        deinit {
            stop()
        }
    }
    
    @StateObject private var minuteTicker = LockAwareTicker()
    
    private let inlinePrimaryFont = Font.system(size: 22, weight: .semibold, design: .rounded)
    private let inlineSecondaryFont = Font.system(size: 13, weight: .medium, design: .rounded)
    private let secondaryLabelColor = Color.white.opacity(0.7)
    private static let sunriseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter
    }()
    
    private var isInline: Bool { snapshot.widgetStyle == .inline }
    private var stackAlignment: VerticalAlignment { isInline ? .firstTextBaseline : .top }
    private var stackSpacing: CGFloat { isInline ? 14 : 22 }
    private var gaugeDiameter: CGFloat { 64 }
    private var topPadding: CGFloat { isInline ? 6 : 22 }
    private var bottomPadding: CGFloat { isInline ? 6 : 10 }
    
    /// A stable width for the lock screen widget so the panel doesn't "lock in" the width
    /// based on whichever row (often `mainWidgetRow`) happened to be shorter at the time.
    private var lockScreenWidgetWidth: CGFloat {
        // Prefer the screen the mouse is on; fall back to main.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let screenWidth = screen?.frame.width ?? 1200
        
        // Use a width that fits comfortably within the screen and matches the panel aesthetic.
        // (This prevents dynamic intrinsic sizing from causing truncation on event switches.)
        let maxWidth = screenWidth - 120
        return max(320, min(800, maxWidth))
    }
    
    private enum CalendarLookaheadWindow: String {
        case mins15 = "15m"
        case mins30 = "30m"
        case hour1 = "1h"
        case hours3 = "3h"
        case hours6 = "6h"
        case hours12 = "12h"
        case restOfDay = "rest_of_day"
        case allTime = "all_time"
        
        var displayTitle: String {
            switch self {
            case .mins15: return "15 mins"
            case .mins30: return "30 mins"
            case .hour1: return "1 hour"
            case .hours3: return "3 hours"
            case .hours6: return "6 hours"
            case .hours12: return "12 hours"
            case .restOfDay: return "Rest of the day"
            case .allTime: return "All time"
            }
        }
        
        var minutes: Int? {
            switch self {
            case .mins15: return 15
            case .mins30: return 30
            case .hour1: return 60
            case .hours3: return 180
            case .hours6: return 360
            case .hours12: return 720
            case .restOfDay, .allTime:
                return nil
            }
        }
    }
    
    private enum CalendarAfterStartWindow: String {
        case min1 = "1m"
        case mins5 = "5m"
        case mins10 = "10m"
        case mins15 = "15m"
        case mins30 = "30m"
        case mins45 = "45m"
        case hour1 = "1h"
        case hours2 = "2h"
        
        var displayTitle: String {
            switch self {
            case .min1: return "1 minute"
            case .mins5: return "5 minutes"
            case .mins10: return "10 minutes"
            case .mins15: return "15 minutes"
            case .mins30: return "30 minutes"
            case .mins45: return "45 minutes"
            case .hour1: return "1 hour"
            case .hours2: return "2 hours"
            }
        }
        
        var minutes: Int {
            switch self {
            case .min1: return 1
            case .mins5: return 5
            case .mins10: return 10
            case .mins15: return 15
            case .mins30: return 30
            case .mins45: return 45
            case .hour1: return 60
            case .hours2: return 120
            }
        }
    }
    
    private var selectedLookaheadWindow: CalendarLookaheadWindow {
        let raw = lockScreenCalendarEventLookaheadWindow
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        
        // Be tolerant of legacy / display-string values from Settings.
        switch raw {
        case "all time", "all_time", "alltime":
            return .allTime
        case "rest of the day", "rest_of_day", "restofday":
            return .restOfDay
        case "15m", "15 mins", "15min", "15mins":
            return .mins15
        case "30m", "30 mins", "30min", "30mins":
            return .mins30
        case "1h", "1 hour", "1hour":
            return .hour1
        case "3h", "3 hours", "3hours":
            return .hours3
        case "6h", "6 hours", "6hours":
            return .hours6
        case "12h", "12 hours", "12hours":
            return .hours12
        default:
            return CalendarLookaheadWindow(rawValue: lockScreenCalendarEventLookaheadWindow) ?? .hours3
        }
    }
    
    private var selectedAfterStartWindow: CalendarAfterStartWindow {
        let raw = lockScreenShowCalendarEventAfterStartWindow
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        
        switch raw {
        case "1m", "1 min", "1 minute", "1min":
            return .min1
        case "5m", "5 min", "5 mins", "5 minutes", "5min":
            return .mins5
        case "10m", "10 min", "10 mins", "10 minutes", "10min":
            return .mins10
        case "15m", "15 min", "15 mins", "15 minutes", "15min":
            return .mins15
        case "30m", "30 min", "30 mins", "30 minutes", "30min":
            return .mins30
        case "45m", "45 min", "45 mins", "45 minutes", "45min":
            return .mins45
        case "1h", "1 hr", "1 hour", "1hour":
            return .hour1
        case "2h", "2 hrs", "2 hours", "2hours", "2hour":
            return .hours2
        default:
            // Default to a sensible value since enable/disable is controlled by the toggle.
            return CalendarAfterStartWindow(rawValue: lockScreenShowCalendarEventAfterStartWindow) ?? .mins5
        }
    }
    
    private func lookaheadEndDate(from now: Date) -> Date? {
        switch selectedLookaheadWindow {
        case .allTime:
            return nil
        case .restOfDay:
            let cal = Calendar.current
            let startOfToday = cal.startOfDay(for: now)
            return cal.date(byAdding: .day, value: 1, to: startOfToday)
        default:
            if let minutes = selectedLookaheadWindow.minutes {
                return Calendar.current.date(byAdding: .minute, value: minutes, to: now)
            }
            return nil
        }
    }
    
    private func isEventEligibleForLookahead(_ event: EventModel, now: Date) -> Bool {
        // Lock screen: do not display all-day events.
        if event.isAllDay {
            return false
        }
        // Ongoing events: if we're in entire-duration mode, allow showing for the remainder.
        if lockScreenShowCalendarEventEntireDuration, event.start <= now, event.end >= now {
            return true
        }
        
        // Upcoming events must start within the selected lookahead window.
        guard event.start > now else { return false }
        
        guard let endDate = lookaheadEndDate(from: now) else {
            // all_time
            return true
        }
        
        // rest_of_day uses endDate = start of next day; other windows are now + minutes.
        return event.start <= endDate
    }
    
    private var lockScreenAllowedCalendarIDs: Set<String>? {
        // "all" => no filter
        guard lockScreenCalendarSelectionMode != "all" else { return nil }
        return lockScreenSelectedCalendarIDs
    }
    
    private func passesLockScreenCalendarFilter(_ event: EventModel) -> Bool {
        guard let allowed = lockScreenAllowedCalendarIDs else { return true }
        // If user chose selected calendars but selected none, show nothing.
        guard !allowed.isEmpty else { return false }
        return allowed.contains(event.calendar.id)
    }
    
    private var nextCalendarEvent: EventModel? {
        let now = currentTime
        
        // If enabled, keep showing the current event for its entire duration.
        // If disabled, we normally show UPCOMING events only — but we can optionally keep
        // showing the just-started event for a short window after it begins.
        
        if lockScreenShowCalendarEventEntireDuration {
            let candidates = calendarManager.lockScreenEvents
                .filter { $0.end >= now }
                .filter(passesLockScreenCalendarFilter)
                .filter { isEventEligibleForLookahead($0, now: now) }
                .sorted { $0.start < $1.start }
            
            return candidates.first
        }
        
        // Entire-duration is OFF.
        // Optional: show the active event for N minutes after it starts.
        let graceMinutes = lockScreenShowCalendarEventAfterStartEnabled
        ? selectedAfterStartWindow.minutes
        : 0
        
        if graceMinutes > 0 {
            let graceEndForEvent: (EventModel) -> Date = { event in
                Calendar.current.date(byAdding: .minute, value: graceMinutes, to: event.start) ?? event.start
            }
            
            // Find an event that has started, has not ended, and we are still within the grace window.
            // (Skip all-day events for this short grace behavior.)
            let activeCandidates = calendarManager.lockScreenEvents
                .filter { !$0.isAllDay }
                .filter(passesLockScreenCalendarFilter)
                .filter { $0.start <= now && $0.end >= now }
                .filter { now <= graceEndForEvent($0) }
                .sorted { $0.start < $1.start }
            
            if let active = activeCandidates.first {
                return active
            }
        }
        
        // Otherwise, show the next UPCOMING event within the lookahead window.
        let upcoming = calendarManager.lockScreenEvents
            .filter { $0.start > now }
            .filter(passesLockScreenCalendarFilter)
            .filter { isEventEligibleForLookahead($0, now: now) }
            .sorted { $0.start < $1.start }
        
        return upcoming.first
    }
    
    private enum RowKind {
        case weather
        case focus
        case calendar
    }
    
    private var orderedRowKinds: [RowKind] {
        switch lockScreenWeatherWidgetRowOrder {
        case "weather_focus_calendar":
            return [.weather, .focus, .calendar]
        case "weather_calendar_focus":
            return [.weather, .calendar, .focus]
        case "focus_weather_calendar":
            return [.focus, .weather, .calendar]
        case "focus_calendar_weather":
            return [.focus, .calendar, .weather]
        case "calendar_weather_focus":
            return [.calendar, .weather, .focus]
        case "calendar_focus_weather":
            return [.calendar, .focus, .weather]
        default:
            return [.weather, .calendar, .focus]
        }
    }
    
    private var enabledRowKinds: [RowKind] {
        // Weather is always present
        var enabled: Set<RowKind> = [.weather]
        
        // Calendar row only present when the feature is enabled
        if lockScreenShowCalendarEvent {
            enabled.insert(.calendar)
        }
        
        // Focus row only present when the focus widget is enabled
        if lockScreenFocusWidgetEnabled {
            enabled.insert(.focus)
        }
        
        return orderedRowKinds.filter { enabled.contains($0) }
    }
    
    private var fullRowOrder: [RowKind] {
        orderedRowKinds
    }
    
    /// Returns whether a given row kind is “active” (i.e. has visible content)
    private func isRowActive(_ kind: RowKind) -> Bool {
        switch kind {
        case .weather:
            return true
        case .focus:
            return shouldShowFocusWidget
        case .calendar:
            return nextCalendarEvent != nil
        }
    }
    
    
    private var shouldCollapseGap: Bool {
        // Only makes sense when we truly have 3 rows in the chosen order
        fullRowOrder.count == 3
    }
    
    private var collapseDistance: CGFloat {
        // 26 is your row height (you already use .frame(height: 26) on rows)
        26 + focusWidgetSpacing
    }
    
    private var collapseOffsetForBottomRow: CGFloat {
        guard shouldCollapseGap else { return 0 }
        
        // Bottom row always moves UP when the middle row is inactive.
        let middleKind = fullRowOrder[1]
        let bottomKind = fullRowOrder[2]
        
        let middleActive = isRowActive(middleKind)
        let bottomActive = isRowActive(bottomKind)
        
        return (!middleActive && bottomActive) ? -collapseDistance : 0
    }
    
    @ViewBuilder
    private func rowView(for kind: RowKind) -> some View {
        switch kind {
        case .weather:
            mainWidgetRow
            
        case .calendar:
            // Placeholder behavior is handled inside nextEventRow via fixed height + opacity
            nextEventRow
            
        case .focus:
            focusWidget
                .opacity(shouldShowFocusWidget ? 1 : 0)   // placeholder behavior like before
                .accessibilityHidden(!shouldShowFocusWidget)
                .allowsHitTesting(false)
        }
    }
    
    private var monochromeGaugeTint: Color {
        Color.white.opacity(0.9)
    }
    
    var body: some View {
        VStack(alignment: .center, spacing: focusWidgetSpacing) {
            ForEach(Array(enabledRowKinds.enumerated()), id: \.offset) { index, kind in
                rowView(for: kind)
                    .offset(y: offsetForRow(index: index))
                    .animation(.easeInOut(duration: 0.3), value: collapseOffsetForBottomRow)
            }
        }
        .id(widgetWidthRemeasureToken)
        .frame(width: lockScreenWidgetWidth, alignment: .center)
        .foregroundStyle(Color.white.opacity(0.65))
        .padding(.horizontal, 0)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .background(Color.clear)
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
        .onReceive(minuteTicker.$now) { currentTime = $0 }
        .onAppear {
            minuteTicker.start()
            minuteTicker.setMinuteAlignedEnabled(lockScreenShowCalendarEvent)
            currentTime = Date()
            calendarRowVisible = shouldShowCalendarRow

            Task {
                await calendarManager.checkCalendarAuthorization()
                await calendarManager.updateLockScreenEvents(force: true)
            }

            if let e = nextCalendarEvent {
                lastCalendarLine = eventLineText(for: e)
            }
        }
        .onChange(of: lockScreenShowCalendarEvent) { _, enabled in
            minuteTicker.setMinuteAlignedEnabled(enabled)
        }
        .onChange(of: lockScreenCalendarEventLookaheadWindow) { _, _ in
            Task { await calendarManager.updateLockScreenEvents(force: true) }
        }
        .onChange(of: lockScreenCalendarSelectionMode) { _, _ in
            Task { await calendarManager.updateLockScreenEvents(force: true) }
        }
        .onChange(of: lockScreenSelectedCalendarIDs) { _, _ in
            Task { await calendarManager.updateLockScreenEvents(force: true) }
        }
        .onDisappear { minuteTicker.stop() }
        .onChange(of: currentCalendarEventID) { _, _ in
            // Force a fresh layout pass when switching events. We do it twice:
            // once immediately, and once shortly after, to avoid any cached/animated measurement
            // from the prior shorter title.
            //
            // IMPORTANT: Do NOT recreate the whole widget when switching to "no_event",
            // otherwise @State resets and the calendar row cannot fade out.
            calendarRowRenderToken &+= 1
            if nextCalendarEvent != nil {
                widgetWidthRemeasureToken &+= 1
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                calendarRowRenderToken &+= 1
                if nextCalendarEvent != nil {
                    widgetWidthRemeasureToken &+= 1
                }
            }
        }
        .onChange(of: currentCalendarEventID) { _, _ in
            // Keep a copy of the last visible line so fade-out can animate smoothly even after `nextCalendarEvent` becomes nil.
            if let e = nextCalendarEvent {
                let newLine = eventLineText(for: e)
                if !newLine.isEmpty {
                    lastCalendarLine = newLine
                }
            }
        }
        .onChange(of: shouldShowCalendarRow) { _, newValue in
            withAnimation(.easeInOut(duration: 0.25)) {
                calendarRowVisible = newValue
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
    
    private func offsetForRow(index: Int) -> CGFloat {
        // We only shift the 3rd row in the 3-row layouts.
        // index is based on enabledRowKinds order, which matches orderedRowKinds filtering.
        // This behavior only triggers when all 3 rows are present (features enabled).
        if enabledRowKinds.count != 3 { return 0 }
        
        // Bottom row (index 2) shifts up when the middle row is inactive
        if index == 2 {
            return collapseOffsetForBottomRow
        }
        
        return 0
    }
    
    
    private var mainWidgetRow: some View {
        HStack(alignment: stackAlignment, spacing: stackSpacing) {
            if let charging = snapshot.charging {
                chargingSegment(for: charging)
            }
            
            if let battery = snapshot.battery {
                batterySegment(for: battery)
            }
            
            bluetoothDevicesSegment()
            
            if let airQuality = snapshot.airQuality {
                airQualitySegment(for: airQuality)
            }
            
            weatherSegment
            
            if snapshot.showsSunrise, let sunriseText = sunriseTimeText {
                sunriseSegment(text: sunriseText)
            }
            
            if shouldShowLocation {
                locationSegment
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 26)
    }
    
    private var sunriseTimeText: String? {
        guard let sunrise = snapshot.sunCycle?.sunrise else { return nil }
        return Self.sunriseFormatter.string(from: sunrise)
    }
    
    @ViewBuilder
    private var weatherSegment: some View {
        switch snapshot.widgetStyle {
        case .inline:
            inlineWeatherSegment
        case .circular:
            circularWeatherSegment
        }
    }
    
    private var inlineWeatherSegment: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: snapshot.symbolName)
                .font(.system(size: 26, weight: .medium))
                .symbolRenderingMode(.hierarchical)
            Text(snapshot.temperatureText)
                .font(inlinePrimaryFont)
                .kerning(-0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .layoutPriority(2)
        }
    }
    
    private var nextEventRow: some View {
        let event = nextCalendarEvent
        // When fading out, `nextCalendarEvent` becomes nil immediately.
        // Keep showing the last line during the fade so the icon does not recenter.
        let line = shouldShowCalendarRow ? eventLineText(for: event) : lastCalendarLine
        
        return HStack(alignment: .center, spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 26, height: 26)
            
            Text(line)
                .font(inlinePrimaryFont)
                .lineLimit(1)
            // Keep the same size; no shrinking/tightening.
                .minimumScaleFactor(1)
                .allowsTightening(false)
                .layoutPriority(10)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 2)
        .frame(height: 26)
        .id(calendarRowRenderToken)
        .opacity(calendarRowVisible ? 1 : 0)
        .accessibilityHidden(!calendarRowVisible)
        .allowsHitTesting(false)
    }
    
    private func eventLineText(for event: EventModel?) -> String {
        guard let event else { return "" }
        
        let now = currentTime
        
        // All-day
        if event.isAllDay {
            return "All day • \(event.title)"
        }
        
        // Start time (matches the examples like "2:00 AM")
        let timeString = event.start.formatted(date: .omitted, time: .shortened)
        
        // Ongoing
        if event.start <= now && event.end >= now {
            // When the event has begun, optionally hide the start time.
            let leading: String
            if lockScreenShowCalendarStartTimeAfterBegins {
                leading = "\(timeString) • "
            } else {
                leading = ""
            }
            
            // Optional time-remaining suffix (independent of entire-duration setting).
            let suffix: String
            if lockScreenShowCalendarTimeRemaining {
                let secondsLeft = event.end.timeIntervalSince(now)
                let minutesLeft = max(0, Int(ceil(secondsLeft / 60.0)))
                suffix = " • \(countdownText(fromMinutes: minutesLeft)) left"
            } else {
                suffix = ""
            }
            
            // No "now" label when time remaining is disabled.
            return "\(leading)\(event.title)\(suffix)"
        }
        
        // Upcoming without countdown
        guard lockScreenShowCalendarCountdown else {
            return "\(timeString) • \(event.title)"
        }
        
        // Upcoming with countdown
        // Use CEIL so we don't show "in 0m" until the event has actually started.
        // (Example: 11:34:10 now, 11:35:00 start => 50s => ceil => 1m)
        let secondsUntilStart = event.start.timeIntervalSince(now)
        let totalMinutes = max(0, Int(ceil(secondsUntilStart / 60.0)))

        return "\(timeString) • \(event.title) • in \(countdownText(fromMinutes: totalMinutes))"
    }
    
    private func countdownText(fromMinutes minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        
        let hours = minutes / 60
        let mins = minutes % 60
        
        if mins == 0 {
            return "\(hours)h"
        }
        
        return "\(hours)h \(mins)m"
    }
    
    @ViewBuilder
    private var circularWeatherSegment: some View {
        if let info = snapshot.temperatureInfo {
            temperatureGauge(for: info)
        } else {
            inlineWeatherSegment
        }
    }
    
    @ViewBuilder
    private func chargingSegment(for info: LockScreenWeatherSnapshot.ChargingInfo) -> some View {
        switch snapshot.widgetStyle {
        case .inline:
            inlineChargingSegment(for: info)
        case .circular:
            circularChargingSegment(for: info)
        }
    }
    
    @ViewBuilder
    private func batterySegment(for info: LockScreenWeatherSnapshot.BatteryInfo) -> some View {
        switch snapshot.widgetStyle {
        case .inline:
            inlineBatterySegment(for: info)
        case .circular:
            circularBatterySegment(for: info)
        }
    }
    
    @ViewBuilder
    private func bluetoothDevicesSegment() -> some View {
        let devices = bluetoothManager.widgetBluetoothDevices()

        if devices.isEmpty {
            EmptyView()
        } else {
            switch snapshot.widgetStyle {
            case .inline:
                // Existing inline-style layout (icon + % on the same row).
                ForEach(devices) { device in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: device.symbolName)
                            .font(.system(size: 24, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)

                        Text(device.batteryLevel.map { "\($0)%" } ?? "—")
                            .font(inlinePrimaryFont)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .layoutPriority(1)
                }

            case .circular:
                // Circular-style layout (Gauge with icon in center + % label below),
                // matching the MacBook battery circular gauge aesthetic.
                ForEach(devices) { device in
                    let level = clampedBatteryLevel(device.batteryLevel ?? 0)

                    VStack(spacing: 6) {
                        Gauge(value: Double(level), in: 0...100) {
                            EmptyView()
                        } currentValueLabel: {
                            Image(systemName: device.symbolName)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color.white)
                        } minimumValueLabel: {
                            EmptyView()
                        } maximumValueLabel: {
                            EmptyView()
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(bluetoothTint(for: level))
                        .frame(width: gaugeDiameter, height: gaugeDiameter)

                        Text(device.batteryLevel.map { "\($0)%" } ?? "—")
                            .font(inlineSecondaryFont)
                            .foregroundStyle(secondaryLabelColor)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                }
            }
        }
    }
    
    private func inlineChargingSegment(for info: LockScreenWeatherSnapshot.ChargingInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let iconName = chargingIconName(for: info) {
                Image(systemName: iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
            }
            Text(inlineChargingLabel(for: info))
                .font(inlinePrimaryFont)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .layoutPriority(1)
    }
    
    @ViewBuilder
    private func circularChargingSegment(for info: LockScreenWeatherSnapshot.ChargingInfo) -> some View {
        if let rawLevel = info.batteryLevel {
            let level = clampedBatteryLevel(rawLevel)
            
            VStack(spacing: 6) {
                Gauge(value: Double(level), in: 0...100) {
                    EmptyView()
                } currentValueLabel: {
                    chargingGlyph(for: info)
                } minimumValueLabel: {
                    Text("0")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryLabelColor)
                } maximumValueLabel: {
                    Text("100")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryLabelColor)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(batteryTint(for: level))
                .frame(width: gaugeDiameter, height: gaugeDiameter)
                
                Text(chargingDetailLabel(for: info))
                    .font(inlineSecondaryFont)
                    .foregroundStyle(secondaryLabelColor)
                    .lineLimit(1)
            }
            .layoutPriority(1)
        } else {
            inlineChargingSegment(for: info)
        }
    }
    
    private func circularBatterySegment(for info: LockScreenWeatherSnapshot.BatteryInfo) -> some View {
        let level = clampedBatteryLevel(info.batteryLevel)
        let symbolName = info.usesLaptopSymbol ? "macbook.gen2" : batteryIconName(for: level)
        
        return VStack(spacing: 6) {
            Gauge(value: Double(level), in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.white)
            } minimumValueLabel: {
                EmptyView()
            } maximumValueLabel: {
                EmptyView()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(batteryTint(for: level))
            .frame(width: gaugeDiameter, height: gaugeDiameter)
            
            Text("\(level)%")
                .font(inlineSecondaryFont)
                .foregroundStyle(secondaryLabelColor)
        }
        .layoutPriority(1)
    }
    
    @ViewBuilder
    private func bluetoothSegment(for info: LockScreenWeatherSnapshot.BluetoothInfo) -> some View {
        switch snapshot.widgetStyle {
        case .inline:
            inlineBluetoothSegment(for: info)
        case .circular:
            circularBluetoothSegment(for: info)
        }
    }
    
    private func inlineBluetoothSegment(for info: LockScreenWeatherSnapshot.BluetoothInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: info.iconName)
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            Text(bluetoothPercentageText(for: info.batteryLevel))
                .font(inlinePrimaryFont)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .layoutPriority(1)
    }
    
    private func inlineBatterySegment(for info: LockScreenWeatherSnapshot.BatteryInfo) -> some View {
        let level = clampedBatteryLevel(info.batteryLevel)
        
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Optional icon (laptop vs battery glyph)
            Image(systemName: info.usesLaptopSymbol ? "macbook.gen2" : batteryIconName(for: level))
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            
            // ✅ The actual percentage text you want in inline style
            Text("\(level)%")
                .font(inlinePrimaryFont)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .layoutPriority(1)
    }
    
    private func circularBluetoothSegment(for info: LockScreenWeatherSnapshot.BluetoothInfo) -> some View {
        let clamped = clampedBatteryLevel(info.batteryLevel)
        
        return VStack(spacing: 6) {
            Gauge(value: Double(clamped), in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: info.iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white)
            } minimumValueLabel: {
                EmptyView()
            } maximumValueLabel: {
                EmptyView()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(bluetoothTint(for: clamped))
            .frame(width: gaugeDiameter, height: gaugeDiameter)
            
            Text(bluetoothPercentageText(for: info.batteryLevel))
                .font(inlineSecondaryFont)
                .foregroundStyle(secondaryLabelColor)
        }
        .layoutPriority(1)
    }
    
    @ViewBuilder
    private func airQualitySegment(for info: LockScreenWeatherSnapshot.AirQualityInfo) -> some View {
        switch snapshot.widgetStyle {
        case .inline:
            inlineAirQualitySegment(for: info)
        case .circular:
            circularAirQualitySegment(for: info)
        }
    }
    
    private func inlineAirQualitySegment(for info: LockScreenWeatherSnapshot.AirQualityInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "wind")
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            inlineComposite(primary: "\(info.scale.compactLabel) \(info.index)", secondary: info.category.displayName)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .layoutPriority(1)
    }
    
    private func circularAirQualitySegment(for info: LockScreenWeatherSnapshot.AirQualityInfo) -> some View {
        let range = info.scale.gaugeRange
        let clampedValue = min(max(Double(info.index), range.lowerBound), range.upperBound)
        
        return VStack(spacing: 6) {
            Gauge(value: clampedValue, in: range) {
                EmptyView()
            } currentValueLabel: {
                Text("\(info.index)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(aqiTint(for: info))
            .frame(width: gaugeDiameter, height: gaugeDiameter)
            
            Text("\(info.scale.compactLabel) · \(info.category.displayName)")
                .font(inlineSecondaryFont)
                .foregroundStyle(secondaryLabelColor)
                .lineLimit(1)
        }
        .layoutPriority(1)
    }
    
    private func temperatureGauge(for info: LockScreenWeatherSnapshot.TemperatureInfo) -> some View {
        let range = temperatureRange(for: info)
        
        return VStack(spacing: 6) {
            Gauge(value: info.current, in: range) {
                EmptyView()
            } currentValueLabel: {
                temperatureCenterLabel(for: info)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(temperatureTint(for: info))
            .frame(width: gaugeDiameter, height: gaugeDiameter)
            
            HStack {
                Text(minimumTemperatureLabel(for: info))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryLabelColor)
                Spacer()
                Text(maximumTemperatureLabel(for: info))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryLabelColor)
            }
            .frame(width: gaugeDiameter)
        }
        .layoutPriority(1)
    }
    
    private var locationSegment: some View {
        Text(snapshot.locationName ?? "")
            .font(isInline ? inlinePrimaryFont : inlineSecondaryFont)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.75)
            .layoutPriority(0.7)
    }
    
    private func sunriseSegment(text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "sunrise.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            Text(text)
                .font(inlinePrimaryFont)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .layoutPriority(0.8)
        .accessibilityLabel("Sunrise at \(text)")
    }
    
    private var shouldShowLocation: Bool {
        snapshot.showsLocation && (snapshot.locationName?.isEmpty == false)
    }
    
    private var focusWidgetSpacing: CGFloat {
        return isInline ? 14 : 20
    }
    
    private var shouldShowFocusWidget: Bool {
        lockScreenFocusWidgetEnabled &&
        focusDetectionEnabled &&
        focusManager.isDoNotDisturbActive &&
        !focusDisplayName.isEmpty
    }
    
    private var shouldShowCalendarRow: Bool {
        lockScreenShowCalendarEvent && nextCalendarEvent != nil
    }
    
    private var focusDisplayName: String {
        let trimmed = focusManager.currentFocusModeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if focusMode == .doNotDisturb {
            return "Do Not Disturb"
        }
        let fallback = focusMode.displayName
        return fallback.isEmpty ? "Focus" : fallback
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
    
    private var focusWidget: some View {
        HStack(alignment: .center, spacing: lockScreenHideFocusLabel ? 0 : 6) {
            focusIcon
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 26, height: 26)
            
            if !lockScreenHideFocusLabel {
                Text(focusDisplayName)
                    .font(inlinePrimaryFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 26)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 2)
        .accessibilityLabel("Focus active: \(focusDisplayName)")
    }
    
    private func chargingIconName(for info: LockScreenWeatherSnapshot.ChargingInfo) -> String? {
        let icon = info.iconName
        return icon.isEmpty ? nil : icon
    }
    
    @ViewBuilder
    private func chargingGlyph(for info: LockScreenWeatherSnapshot.ChargingInfo) -> some View {
        if let iconName = chargingIconName(for: info) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white)
        } else {
            Image(systemName: "bolt.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white)
        }
    }
    
    private func inlineChargingLabel(for info: LockScreenWeatherSnapshot.ChargingInfo) -> String {
        if let time = formattedChargingTime(for: info) {
            return time
        }
        return chargingStatusFallback(for: info)
    }
    
    private func chargingDetailLabel(for info: LockScreenWeatherSnapshot.ChargingInfo) -> String {
        inlineChargingLabel(for: info)
    }
    
    private func formattedChargingTime(for info: LockScreenWeatherSnapshot.ChargingInfo) -> String? {
        guard let minutes = info.minutesRemaining, minutes > 0 else {
            return nil
        }
        
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        
        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(remainingMinutes)m"
    }
    
    private func chargingStatusFallback(for info: LockScreenWeatherSnapshot.ChargingInfo) -> String {
        if info.isPluggedIn && !info.isCharging {
            return NSLocalizedString("Fully charged", comment: "Charging fallback label when already charged")
        }
        return NSLocalizedString("Charging", comment: "Charging fallback label when no estimate is available")
    }
    
    private func bluetoothPercentageText(for level: Int) -> String {
        "\(clampedBatteryLevel(level))%"
    }
    
    private func minimumTemperatureLabel(for info: LockScreenWeatherSnapshot.TemperatureInfo) -> String {
        if let minimum = info.displayMinimum {
            return "\(minimum)°"
        }
        return "—"
    }
    
    private func maximumTemperatureLabel(for info: LockScreenWeatherSnapshot.TemperatureInfo) -> String {
        if let maximum = info.displayMaximum {
            return "\(maximum)°"
        }
        return "—"
    }
    
    private func temperatureCenterLabel(for info: LockScreenWeatherSnapshot.TemperatureInfo) -> some View {
        return HStack(alignment: .top, spacing: 2) {
            Text("\(info.displayCurrent)°")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Color.white)
    }
    
    private func temperatureRange(for info: LockScreenWeatherSnapshot.TemperatureInfo) -> ClosedRange<Double> {
        let minimumCandidate = info.minimum ?? info.current
        let maximumCandidate = info.maximum ?? info.current
        var lowerBound = min(minimumCandidate, info.current)
        var upperBound = max(maximumCandidate, info.current)
        
        if lowerBound == upperBound {
            lowerBound -= 1
            upperBound += 1
        }
        
        return lowerBound...upperBound
    }
    
    private func clampedBatteryLevel(_ level: Int) -> Int {
        min(max(level, 0), 100)
    }
    
    private func inlineComposite(primary: String, secondary: String?) -> Text {
        var text = Text(primary).font(inlinePrimaryFont)
        if let secondary, !secondary.isEmpty {
            text = text + Text(" \(secondary)")
                .font(inlineSecondaryFont)
                .foregroundStyle(secondaryLabelColor)
        }
        return text
    }
    
    private func batteryTint(for level: Int) -> Color {
        guard snapshot.usesGaugeTint else { return monochromeGaugeTint }
        let clamped = clampedBatteryLevel(level)
        switch clamped {
        case ..<20:
            return Color(.systemRed)
        case 20..<50:
            return Color(.systemOrange)
        default:
            return Color(.systemGreen)
        }
    }
    
    private func bluetoothTint(for level: Int) -> Color {
        guard snapshot.usesGaugeTint else { return monochromeGaugeTint }
        let clamped = clampedBatteryLevel(level)
        switch clamped {
        case ..<20:
            return Color(.systemRed)
        case 20..<50:
            return Color(.systemOrange)
        default:
            return Color(.systemGreen)
        }
    }
    
    private func aqiTint(for info: LockScreenWeatherSnapshot.AirQualityInfo) -> Color {
        guard snapshot.usesGaugeTint else { return monochromeGaugeTint }
        switch info.category {
        case .good:
            return Color(red: 0.20, green: 0.79, blue: 0.39)
        case .fair:
            return Color(red: 0.55, green: 0.85, blue: 0.32)
        case .moderate:
            return Color(red: 0.97, green: 0.82, blue: 0.30)
        case .unhealthyForSensitive:
            return Color(red: 0.98, green: 0.57, blue: 0.24)
        case .unhealthy:
            return Color(red: 0.91, green: 0.29, blue: 0.25)
        case .poor:
            return Color(red: 0.98, green: 0.57, blue: 0.24)
        case .veryPoor:
            return Color(red: 0.91, green: 0.29, blue: 0.25)
        case .veryUnhealthy:
            return Color(red: 0.65, green: 0.32, blue: 0.86)
        case .extremelyPoor:
            return Color(red: 0.50, green: 0.13, blue: 0.28)
        case .hazardous:
            return Color(red: 0.50, green: 0.13, blue: 0.28)
        case .unknown:
            return Color(red: 0.63, green: 0.66, blue: 0.74)
        }
    }
    
    private func temperatureTint(for info: LockScreenWeatherSnapshot.TemperatureInfo) -> Color {
        guard snapshot.usesGaugeTint else { return monochromeGaugeTint }
        let value = info.current
        switch value {
        case ..<0:
            return Color(red: 0.29, green: 0.63, blue: 1.00)
        case 0..<15:
            return Color(red: 0.20, green: 0.79, blue: 0.93)
        case 15..<25:
            return Color(red: 0.20, green: 0.79, blue: 0.39)
        case 25..<32:
            return Color(red: 0.97, green: 0.58, blue: 0.29)
        default:
            return Color(red: 0.91, green: 0.29, blue: 0.25)
        }
    }
    
    private var accessibilityLabel: String {
        var components: [String] = []
        
        if snapshot.showsLocation, let locationName = snapshot.locationName, !locationName.isEmpty {
            components.append(
                String(
                    format: NSLocalizedString("Weather: %@ %@ in %@", comment: "Weather description, temperature, and location"),
                    snapshot.description,
                    snapshot.temperatureText,
                    locationName
                )
            )
        } else {
            components.append(
                String(
                    format: NSLocalizedString("Weather: %@ %@", comment: "Weather description and temperature"),
                    snapshot.description,
                    snapshot.temperatureText
                )
            )
        }
        
        if let charging = snapshot.charging {
            components.append(accessibilityChargingText(for: charging))
        }
        
        if let bluetooth = snapshot.bluetooth {
            components.append(accessibilityBluetoothText(for: bluetooth))
        }
        
        if let airQuality = snapshot.airQuality {
            components.append(accessibilityAirQualityText(for: airQuality))
        }
        
        if let battery = snapshot.battery, !isInline {
            components.append(accessibilityBatteryText(for: battery))
        }
        
        if shouldShowFocusWidget {
            components.append("Focus active: \(focusDisplayName)")
        }
        
        return components.joined(separator: ". ")
    }
    
    private func accessibilityChargingText(for charging: LockScreenWeatherSnapshot.ChargingInfo) -> String {
        if let minutes = charging.minutesRemaining, minutes > 0 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .full
            let duration = formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) minutes"
            return String(
                format: NSLocalizedString("Battery charging, %@ remaining", comment: "Charging time remaining"),
                duration
            )
        }
        
        if charging.isPluggedIn && !charging.isCharging {
            return NSLocalizedString("Battery fully charged", comment: "Battery is full")
        }
        
        if snapshot.showsChargingPercentage, let level = charging.batteryLevel {
            return String(
                format: NSLocalizedString("Battery at %d percent", comment: "Battery percentage"),
                level
            )
        }
        
        return NSLocalizedString("Battery charging", comment: "Battery charging without estimate")
    }
    
    private func accessibilityBluetoothText(for bluetooth: LockScreenWeatherSnapshot.BluetoothInfo) -> String {
        String(
            format: NSLocalizedString("Bluetooth device %@ at %d percent", comment: "Bluetooth device battery"),
            bluetooth.deviceName,
            bluetooth.batteryLevel
        )
    }
    
    private func accessibilityAirQualityText(for airQuality: LockScreenWeatherSnapshot.AirQualityInfo) -> String {
        String(
            format: NSLocalizedString("Air quality index %d, %@", comment: "Air quality accessibility label"),
            airQuality.index,
            "\(airQuality.scale.accessibilityLabel) \(airQuality.category.displayName)"
        )
    }
    
    private func accessibilityBatteryText(for battery: LockScreenWeatherSnapshot.BatteryInfo) -> String {
        String(
            format: NSLocalizedString("Mac battery at %d percent", comment: "Mac battery gauge accessibility label"),
            clampedBatteryLevel(battery.batteryLevel)
        )
    }
    
    private func batteryIconName(for level: Int) -> String {
        let clamped = clampedBatteryLevel(level)
        switch clamped {
        case ..<10:
            return "battery.0percent"
        case 10..<40:
            return "battery.25percent"
        case 40..<70:
            return "battery.50percent"
        case 70..<90:
            return "battery.75percent"
        default:
            return "battery.100percent"
        }
    }

}

#if DEBUG

/// Xcode Canvas preview so you can iterate on layout without rebuilding/running the full app.
///
/// NOTE: This assumes `LockScreenWeatherSnapshot` has a default initializer.
/// If your snapshot requires parameters, replace `LockScreenWeatherSnapshot()` with whatever
/// sample/mock snapshot you already use elsewhere in the project.
#Preview("Lock Screen Weather Widget") {
    LockScreenWeatherWidget(
        snapshot: LockScreenWeatherSnapshot(
            temperatureText: "12°",
            symbolName: "cloud.sun.fill",
            description: "Partly Cloudy",
            locationName: "Victoria",
            charging: nil,
            bluetooth: nil,
            battery: nil,
            showsLocation: true,
            airQuality: nil,
            widgetStyle: .circular,
            showsChargingPercentage: true,
            temperatureInfo: nil,
            usesGaugeTint: true,
            sunCycle: nil,
            showsSunrise: false
        )
    )
        .padding(24)
        .background(Color.black)
        .previewLayout(.sizeThatFits)
}

#endif
