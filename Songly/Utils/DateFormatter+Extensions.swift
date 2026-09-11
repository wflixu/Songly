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
}
