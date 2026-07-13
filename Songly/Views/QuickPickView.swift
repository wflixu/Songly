//
//  QuickPickView.swift
//  Songly
//
//  3-button grid for QuickPick style selection.
//

import SwiftUI
import SwiftData

struct QuickPickView: View {
    @Bindable var viewModel: QuickPickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("想听点什么？")
                .font(.headline)

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ],
                spacing: 12
            ) {
                ForEach(QuickPickStyle.mvpStyles, id: \.self) { style in
                    StyleButton(
                        style: style,
                        action: { viewModel.selectStyle(style) },
                        isEnabled: viewModel.canSelect
                    )
                }
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    QuickPickView(
        viewModel: QuickPickViewModel(
            engine: RecommendationEngine(
                musicKitService: MusicKitService(),
                llmService: MockLLMService(),
                playlistService: PlaylistService(),
                modelContainer: try! ModelContainer(for: RecommendationRecord.self)
            )
        )
    )
}
