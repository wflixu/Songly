//
//  StyleButton.swift
//  Songly
//

import SwiftUI

struct StyleButton: View {
    let style: QuickPickStyle
    let action: () -> Void
    var isEnabled: Bool = true

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(style.emoji)
                    .font(.system(size: 28))
                Text(style.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 80)
        }
        .buttonStyle(.plain)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .disabled(!isEnabled)
        .accessibilityLabel("\(style.rawValue)风格歌单")
    }
}

#Preview {
    HStack {
        StyleButton(style: .rock, action: {})
        StyleButton(style: .jazz, action: {})
        StyleButton(style: .surprise, action: {})
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
