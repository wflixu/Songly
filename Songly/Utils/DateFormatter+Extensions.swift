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
}

extension Date {
    /// "7月13日" format.
    var chineseDateString: String {
        DateFormatter.chineseDate.string(from: self)
    }

    /// "星期一" format.
    var chineseWeekdayString: String {
        DateFormatter.chineseWeekday.string(from: self)
    }

    /// "7月13日" format for playlist names.
    var playlistDateString: String {
        DateFormatter.playlistDate.string(from: self)
    }
}
