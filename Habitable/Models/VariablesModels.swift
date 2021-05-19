//
//  VariablesModels.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/17/21.
//

import SwiftUI

class TerraformVariable: ObservableObject {
    var id = UUID()
    @Published var key: String = ""
    @Published var value: String = ""
    @Published var description: String = ""
    @Published var sensitive = false
    @Published var hcl = false
}

class EnvironmentVariable: ObservableObject {
    var id = UUID()
    @Published var key: String = ""
    @Published var value: String = ""
    @Published var description: String = ""
    @Published var sensitive = false
}

