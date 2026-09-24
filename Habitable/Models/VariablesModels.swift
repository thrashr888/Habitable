//
//  VariablesModels.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/17/21.
//

import SwiftUI

enum VariableInputError: LocalizedError, Equatable {
    case invalidKey(String)
    case duplicateKey(String)
    case invalidJSON(String)
    case invalidEnvironmentValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey(let key): return "Variable key '\(key)' must use a Terraform identifier (letters, numbers, and underscores; it cannot start with a number)."
        case .duplicateKey(let key): return "Variable key '\(key)' is listed more than once."
        case .invalidJSON(let key): return "Value for '\(key)' must be a valid JSON string, number, boolean, list, map, or null."
        case .invalidEnvironmentValue(let key): return "Environment variable '\(key)' contains a null character."
        }
    }
}

private func isTerraformIdentifier(_ key: String) -> Bool {
    key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
}

class TerraformVariable: ObservableObject {
    var id = UUID()
    @Published var key: String = ""
    @Published var value: String = ""
    @Published var description: String = ""
    @Published var sensitive = false
    @Published var hcl = false
    /// True only for values explicitly saved in the editor. Workspace files
    /// discovered by the refresh action stay Terraform-managed/display-only.
    @Published var isUserInput = false

    /// The value to place in Terraform's JSON variable file. Structured values
    /// are entered as JSON so strings, equals signs, and nested values survive
    /// without lossy HCL splitting or shell quoting.
    func terraformJSONValue() throws -> Any {
        guard isTerraformIdentifier(key) else { throw VariableInputError.invalidKey(key) }
        guard hcl else { return value }
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw VariableInputError.invalidJSON(key)
        }
        return json
    }

    var validationError: String? {
        do { _ = try terraformJSONValue(); return nil }
        catch { return error.localizedDescription }
    }
}

class EnvironmentVariable: ObservableObject {
    var id = UUID()
    @Published var key: String = ""
    @Published var value: String = ""
    @Published var description: String = ""
    @Published var sensitive = false
    @Published var isUserInput = false

    func validate() throws {
        guard !key.isEmpty, !key.contains("="), !key.contains("\0") else {
            throw VariableInputError.invalidKey(key)
        }
        guard !value.contains("\0") else { throw VariableInputError.invalidEnvironmentValue(key) }
    }

    var validationError: String? {
        do { try validate(); return nil }
        catch { return error.localizedDescription }
    }
}
