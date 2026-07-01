//
//  reader.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 05/03/2026
//  Using Swift 6.0
//  Running on macOS 26.3
//
//  Copyright © 2026 Serhiy Mytrovtsiy. All rights reserved.
//  

import Foundation
import Kit

internal class ClockReader: Reader<Date> {
    public override func setup() {
        self.alignToSecondBoundary = true
    }
    
    public override func read() {
        self.callback(Date())
    }
}
