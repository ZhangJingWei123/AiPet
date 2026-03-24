import Foundation

#if canImport(EventKit)
import EventKit

/// 日历 & 提醒事项读取服务
///
/// - 负责向用户申请日历/提醒权限；
/// - 读取当天的日历事件与待办事项；
/// - 将结果整理成适合注入系统 Prompt 的自然语言串。
final class CalendarService {
    static let shared = CalendarService()

    private let eventStore = EKEventStore()

    enum CalendarError: Error {
        case accessDenied
        case accessRestricted
    }

    private init() {}

    /// 读取「今天」的日程与待办摘要，失败或无内容时返回 nil。
    func fetchTodayScheduleSummary() async throws -> String? {
        try await requestAccessIfNeeded()

        let now = Date()
        let calendar = Calendar.current

        guard
            let startOfDay = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: now),
            let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now)
        else {
            return nil
        }

        // 当天日历事件
        let eventCalendars = eventStore.calendars(for: .event)
        let eventPredicate = eventStore.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: eventCalendars
        )
        let events = eventStore
            .events(matching: eventPredicate)
            .sorted { $0.startDate < $1.startDate }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        var eventStrings: [String] = []
        for event in events {
            let time = timeFormatter.string(from: event.startDate)
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false ? event.title! : "日程"
            eventStrings.append("\(time) \(title)")
        }

        // 当天提醒事项（未完成）
        let reminderCalendars = eventStore.calendars(for: .reminder)
        var reminderTitles: [String] = []
        if !reminderCalendars.isEmpty {
            let predicate = eventStore.predicateForReminders(in: reminderCalendars)
            let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: reminders ?? [])
                }
            }

            for reminder in reminders where !reminder.isCompleted {
                let title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                reminderTitles.append(title)
            }
        }

        // 如果既没有事件也没有待办，就不打扰模型
        guard !eventStrings.isEmpty || !reminderTitles.isEmpty else {
            return nil
        }

        var segments: [String] = []
        if !eventStrings.isEmpty {
            let joined = eventStrings.prefix(8).joined(separator: "，")
            segments.append("今天的日历日程包括：\(joined)")
        }
        if !reminderTitles.isEmpty {
            let joined = reminderTitles.prefix(8).joined(separator: "，")
            segments.append("今天的待办事项包括：\(joined)")
        }

        return segments.joined(separator: "。") + "。"
    }

    // MARK: - 授权

    private func requestAccessIfNeeded() async throws {
        // 日历权限
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized:
            break
        case .notDetermined:
            let granted: Bool
            if #available(iOS 17.0, *) {
                granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    eventStore.requestFullAccessToEvents { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                }
            } else {
                granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    eventStore.requestAccess(to: .event) { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                }
            }
            if !granted { throw CalendarError.accessDenied }
        case .denied:
            throw CalendarError.accessDenied
        case .restricted:
            throw CalendarError.accessRestricted
        @unknown default:
            throw CalendarError.accessDenied
        }

        // 提醒事项权限（尽量申请，失败则仅使用日历事件）
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized:
            break
        case .notDetermined:
            if #available(iOS 17.0, *) {
                eventStore.requestFullAccessToReminders { _, _ in }
            } else {
                eventStore.requestAccess(to: .reminder) { _, _ in }
            }
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }
}

#else

/// 非 iOS / 无 EventKit 平台上的空实现，避免编译错误。
final class CalendarService {
    static let shared = CalendarService()
    private init() {}

    func fetchTodayScheduleSummary() async throws -> String? {
        return nil
    }
}

#endif
