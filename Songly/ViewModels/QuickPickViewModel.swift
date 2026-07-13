//
//  QuickPickViewModel.swift
//  Songly
//
//  @Observable @MainActor: manages QuickPick style selection and recommendation.
//

import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class QuickPickViewModel {
    private(set) var selectedStyle: QuickPickStyle?
    private(set) var state: RecommendationState = .idle

    private let engine: RecommendationEngine

    var isLoading: Bool {
        switch state {
        case .idle, .completed, .error, .onboarding:
            return false
        default:
            return true
        }
    }

    var canSelect: Bool {
        if case .error = state { return false }
        if case .idle = state { return true }
        if case .completed = state { return true }
        return false
    }

    init(engine: RecommendationEngine) {
        self.engine = engine
    }

    func selectStyle(_ style: QuickPickStyle) {
        guard canSelect else { return }
        selectedStyle = style
        state = .readingLibrary

        Task {
            await engine.runQuickPickRecommendation(style: style) { [weak self] nextState in
                Task { @MainActor in
                    self?.state = nextState
                }
            }
        }
    }
}
