//
//  Item.swift
//  Songly
//
//  Created by luke on 2026/7/12.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
