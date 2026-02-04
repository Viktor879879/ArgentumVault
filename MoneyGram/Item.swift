//
//  Item.swift
//  MoneyGram
//
//  Created by Viktor Parshyn on 2026-02-04.
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
