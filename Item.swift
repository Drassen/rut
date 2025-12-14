//
//  Item.swift
//  Rut
//
//  Created by Andreas Pantesjö on 2025-11-24.
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
