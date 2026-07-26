//
//  StylePickerView.swift
//  Songly
//
//  Bottom sheet presenting style options for playlist generation.
//  8 style presets in a 2-column grid. Dismisses on selection.
//

import SwiftUI

struct StylePickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (QuickPickStyle) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Subtitle
                Text("选择一种风格，AI 将为你推荐对应的好歌")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)

                // Style grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(QuickPickStyle.allStyles, id: \.self) { style in
                            styleCard(style)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("选择风格生成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func styleCard(_ style: QuickPickStyle) -> some View {
        Button {
            dismiss()
            onSelect(style)
        } label: {
            VStack(spacing: 10) {
                Text(style.emoji)
                    .font(.system(size: 36))

                Text(style.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.rawValue)歌单")
    }
}

#Preview {
    StylePickerView(onSelect: { _ in })
}
