//
//  CalendarManager.swift
//  DynamicIsland
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var lockScreenEvents: [EventModel] = []

    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()
    private var lastEventsFetchDate: Date?
    private let reloadRefreshInterval: TimeInterval = 15
    private var eventStoreChangedObserver: NSObjectProtocol?
    private var pendingEventStoreRefreshTask: Task<Void, Never>?
    private var nextAllowedEventStoreRefresh: Date = .distantPast
    private var ignoreEventStoreChangesUntil: Date = .distantPast
    private let eventStoreChangeThrottle: TimeInterval = 20
    private let selfInducedChangeSuppression: TimeInterval = 6
    private let eventFetchLimiter = EventFetchLimiter()
    private var lastLockScreenEventsFetchDate: Date?
    private let lockScreenRefreshInterval: TimeInterval = 15
    private var lockScreenRefreshTask: Task<Void, Never>?

    var hasCalendarAccess: Bool { isAuthorized(calendarAuthorizationStatus) }
    var hasReminderAccess: Bool { isAuthorized(reminderAuthorizationStatus) }

    private init() {
        currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        startLockScreenRefreshLoop()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingEventStoreRefreshTask?.cancel()
        lockScreenRefreshTask?.cancel()
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleEventStoreChanged()
        }
    }

    private func handleEventStoreChanged() {
        Logger.log("CalendarManager: Event store changed notification received", category: .lifecycle)
        let now = Date()
        guard now >= ignoreEventStoreChangesUntil else { return }

        if now < nextAllowedEventStoreRefresh {
            let delay = max(nextAllowedEventStoreRefresh.timeIntervalSince(now), 0.05)
            scheduleEventStoreRefresh(after: delay)
            return
        }

        nextAllowedEventStoreRefresh = now.addingTimeInterval(eventStoreChangeThrottle)
        scheduleEventStoreRefresh(after: 0)
    }

    private func scheduleEventStoreRefresh(after delay: TimeInterval) {
        pendingEventStoreRefreshTask?.cancel()
        pendingEventStoreRefreshTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            await self.performEventStoreRefresh()
        }
    }

    @MainActor
    private func performEventStoreRefresh() async {
        pendingEventStoreRefreshTask = nil
        await reloadCalendarAndReminderLists()
        await maybeRefreshEventsAfterReload()
        // Also refresh the lock screen feed so edits/new day show without opening the Dynamic Island
        await updateLockScreenEvents(force: true)
        nextAllowedEventStoreRefresh = Date().addingTimeInterval(eventStoreChangeThrottle)
        ignoreEventStoreChangesUntil = Date().addingTimeInterval(selfInducedChangeSuppression)
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let allCalendars = await calendarService.calendars()
        eventCalendars = allCalendars.filter { !$0.isReminder }
        reminderLists = allCalendars.filter { $0.isReminder }
        self.allCalendars = allCalendars
        updateSelectedCalendars()
    }

    @MainActor
    private func maybeRefreshEventsAfterReload() async {
        guard hasCalendarAccess else { return }
        let now = Date()
        if let lastFetch = lastEventsFetchDate, now.timeIntervalSince(lastFetch) < reloadRefreshInterval {
            return
        }
        await updateEvents()
    }

    private func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        calendarAuthorizationStatus = status

        switch status {
        case .notDetermined:
            let granted = await calendarService.requestAccess(to: .event)
            calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                await updateEvents(force: true)
                await updateLockScreenEvents(force: true)
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .authorized, .fullAccess:
            await reloadCalendarAndReminderLists()
            await updateEvents(force: true)
            await updateLockScreenEvents(force: true)
        case .writeOnly:
            NSLog("Calendar write only")
        @unknown default:
            NSLog("Unknown calendar authorization status")
        }
    }

    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        reminderAuthorizationStatus = status

        switch status {
        case .notDetermined:
            let granted = await calendarService.requestAccess(to: .reminder)
            reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .authorized, .fullAccess:
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Reminder write only")
        @unknown default:
            NSLog("Unknown reminder authorization status")
        }
    }

    func updateSelectedCalendars() {
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }
        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            if identifiers.isEmpty || identifiers.count == allCalendars.count {
                selectionState = .all
            } else {
                selectionState = .selected(identifiers)
            }
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents(force: true)
        await updateLockScreenEvents(force: true)
    }

    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents(force: true)
        await updateLockScreenEvents(force: true)
    }
    
    func updateLockScreenEvents(force: Bool = false) async {
        let now = Date()

        if !force,
           let lastFetch = lastLockScreenEventsFetchDate,
           now.timeIntervalSince(lastFetch) < lockScreenRefreshInterval {
            return
        }

        let lookaheadRaw = Defaults[.lockScreenCalendarEventLookaheadWindow]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let isAllTimeLookahead =
            lookaheadRaw == "all_time" ||
            lookaheadRaw == "all time" ||
            lookaheadRaw == "alltime"

        let isRestOfDay =
            lookaheadRaw == "rest_of_day" ||
            lookaheadRaw == "rest of the day" ||
            lookaheadRaw == "restofday"

        func lookaheadMinutes(from raw: String) -> Int? {
            switch raw {
            case "15m", "15 min", "15 mins", "15min", "15mins": return 15
            case "30m", "30 min", "30 mins", "30min", "30mins": return 30
            case "1h", "1 hr", "1 hour", "1hour": return 60
            case "3h", "3 hr", "3 hours", "3hours": return 180
            case "6h", "6 hr", "6 hours", "6hours": return 360
            case "12h", "12 hr", "12 hours", "12hours": return 720
            default: return nil
            }
        }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)

        // Start slightly in the past so overnight/ongoing events are included.
        let startDate = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday

        let endDate: Date
        if isAllTimeLookahead {
            endDate = cal.date(byAdding: .day, value: 365, to: now) ?? now.addingTimeInterval(365 * 24 * 3600)
        } else if isRestOfDay {
            endDate = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(24 * 3600)
        } else if let mins = lookaheadMinutes(from: lookaheadRaw) {
            endDate = cal.date(byAdding: .minute, value: mins, to: now) ?? now.addingTimeInterval(TimeInterval(mins * 60))
        } else {
            // safe fallback: 3 hours
            endDate = cal.date(byAdding: .minute, value: 180, to: now) ?? now.addingTimeInterval(180 * 60)
        }

        let calendarIDs = selectedCalendars.map { $0.id }
        let service = calendarService

        let fetched = await eventFetchLimiter.run {
            await service.events(from: startDate, to: endDate, calendars: calendarIDs)
        }

        if self.lockScreenEvents == fetched {
            lastLockScreenEventsFetchDate = Date()
            return
        }

        withAnimation(.smooth(duration: 0.25)) {
            self.lockScreenEvents = fetched
        }
        lastLockScreenEventsFetchDate = Date()
    }

    private func startLockScreenRefreshLoop() {
        lockScreenRefreshTask?.cancel()
        lockScreenRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Refresh once a minute so midnight rollover and event edits show up
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                guard self.hasCalendarAccess else { continue }
                await self.updateLockScreenEvents(force: false)
            }
        }
    }

    private func updateEvents(force: Bool = false) async {
        let now = Date()

        // Determine if lock screen lookahead is set to "All time"
        let lookaheadRaw = Defaults[.lockScreenCalendarEventLookaheadWindow]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let isAllTimeLookahead =
            lookaheadRaw == "all_time" ||
            lookaheadRaw == "all time" ||
            lookaheadRaw == "alltime"

        // Avoid refetching large ranges too frequently
        let effectiveRefreshInterval: TimeInterval =
            isAllTimeLookahead ? 300 : reloadRefreshInterval

        if !force,
           let lastFetch = lastEventsFetchDate,
           now.timeIntervalSince(lastFetch) < effectiveRefreshInterval {
            return
        }

        Logger.log(
            "CalendarManager: Updating events (force: \(force), allTime: \(isAllTimeLookahead))",
            category: .lifecycle
        )

        let calendarIDs = selectedCalendars.map { $0.id }
        let startDate = currentWeekStartDate

        let endDate: Date
        if isAllTimeLookahead {
            // Fetch far enough ahead that the *next* event is guaranteed to exist
            // 1 year is a safe, performant upper bound
            guard let farEnd = Calendar.current.date(byAdding: .day, value: 365, to: startDate) else {
                return
            }
            endDate = farEnd
        } else {
            // Default behavior: today only
            guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: startDate) else {
                return
            }
            endDate = dayEnd
        }

        let service = calendarService

        let events = await eventFetchLimiter.run {
            await service.events(
                from: startDate,
                to: endDate,
                calendars: calendarIDs
            )
        }

        // If nothing changed, don't animate / re-render unnecessarily
        if self.events == events {
            lastEventsFetchDate = Date()
            return
        }

        // Focus-style animated publish
        withAnimation(.smooth(duration: 0.25)) {
            self.events = events
        }

        lastEventsFetchDate = Date()
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        await updateEvents(force: true)
    }
}

// MARK: - Event Fetch Limiter

private actor EventFetchLimiter {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isRunning = false

    func run<T>(_ operation: @escaping @Sendable () async -> T) async -> T {
        await waitTurn()
        defer { resumeNext() }
        return await operation()
    }

    private func waitTurn() async {
        if !isRunning {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resumeNext() {
        if waiters.isEmpty {
            isRunning = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}
