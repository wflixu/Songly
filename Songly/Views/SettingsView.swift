//
//  SettingsView.swift
//  Songly
//

import SwiftUI
import MusicKit
import UIKit
import UserNotifications

struct SettingsView: View {
    @State private var authOk = false
    @State private var notifyOk = false

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "music.note")
                        .foregroundStyle(.red)
                    Text("Apple Music")
                    Spacer()
                    if authOk {
                        Text("已授权").foregroundStyle(.secondary)
                    } else {
                        Button("去设置") { openSettings() }
                            .font(.subheadline).buttonStyle(.bordered).controlSize(.small)
                    }
                }
                HStack {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(.orange)
                    Text("通知")
                    Spacer()
                    if notifyOk {
                        Text("已开启").foregroundStyle(.secondary)
                    } else {
                        Button("去设置") { openSettings() }
                            .font(.subheadline).buttonStyle(.bordered).controlSize(.small)
                    }
                }
            } header: {
                Text("权限")
            }

            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("1.0.0").foregroundStyle(.secondary)
                }
            } header: {
                Text("关于")
            }
        }
        .scrollContentBackground(.hidden)
        .task {
            authOk = MusicAuthorization.currentStatus == .authorized
            let s = await UNUserNotificationCenter.current().notificationSettings()
            notifyOk = s.authorizationStatus == .authorized
        }
    }

    private func openSettings() {
        if let u = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(u)
        }
    }
}

#Preview { SettingsView() }
