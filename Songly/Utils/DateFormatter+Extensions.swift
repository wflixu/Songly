//
//  DateFormatter+Extensions.swift
//  Songly
//
//  Chinese-locale date formatting utilities.
//

import Foundation

extension DateFormatter {
    /// "7月13日" format.
    static let chineseDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    /// "星期一" format.
    static let chineseWeekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    /// "7月13日" for playlist naming.
    static let playlistDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    /// "20260809" format for playlist naming.
    static let compactDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    /// "22:04" format.
    static let timeOfDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

extension Date {
    /// "7月13日" format.
    nonisolated var chineseDateString: String {
        DateFormatter.chineseDate.string(from: self)
    }

    /// "星期一" format.
    nonisolated var chineseWeekdayString: String {
        DateFormatter.chineseWeekday.string(from: self)
    }

    /// "7月13日" format for playlist names.
    nonisolated var playlistDateString: String {
        DateFormatter.playlistDate.string(from: self)
    }

    /// "20260809" format for playlist names.
    nonisolated var yyyyMMddString: String {
        DateFormatter.compactDate.string(from: self)
    }

    /// 「今天 22:04」/「昨天」/「7月13日」—— 列表行里的相对时间。
    ///
    /// 今天刻意带上时刻：同一天内可能生成多份（重试、QuickPick），
    /// 只显示「今天」会让两行看起来一模一样。
    nonisolated var relativeDayString: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return "今天 " + DateFormatter.timeOfDay.string(from: self)
        }
        if calendar.isDateInYesterday(self) {
            return "昨天"
        }
        return chineseDateString
    }
}
