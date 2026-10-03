//
//  VariablesModels.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/17/21.
//

import SwiftUI
import CoreFoundation

enum VariableInputError: LocalizedError, Equatable {
    case invalidKey(String)
    case invalidEnvironmentKey(String)
    case duplicateKey(String)
    case invalidJSON(String)
    case invalidEnvironmentValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey(let key): return "Variable key '\(key)' must use a Terraform identifier (letters, numbers, and underscores; it cannot start with a number)."
        case .invalidEnvironmentKey(let key): return "Environment variable key '\(key)' must be non-empty and cannot contain '=' or a null character."
        case .duplicateKey(let key): return "Variable key '\(key)' is listed more than once."
        case .invalidJSON(let key): return "Value for '\(key)' must be a valid JSON string, number, boolean, list, map, or null."
        case .invalidEnvironmentValue(let key): return "Environment variable '\(key)' contains a null character."
        }
    }
}

private func isTerraformIdentifier(_ key: String) -> Bool {
    key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
}

enum TerraformVariableEditorMode: String, CaseIterable, Identifiable {
    case string = "String"
    case number = "Number"
    case boolean = "Boolean"
    case rawJSON = "Raw JSON"

    var id: String { rawValue }

    static func mode(for type: String?) -> TerraformVariableEditorMode {
        let normalized = (type ?? "string").trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "string": return .string
        case "number": return .number
        case "bool": return .boolean
        default: return .rawJSON
        }
    }

    static func reopeningMode(for type: String?, value: String, isJSON: Bool) -> TerraformVariableEditorMode {
        let declaredMode = mode(for: type)
        guard isJSON else { return declaredMode }
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              !(json is NSNull) else { return .rawJSON }
        switch declaredMode {
        case .boolean: return value == "true" || value == "false" ? .boolean : .rawJSON
        case .number:
            guard let number = json as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return .rawJSON }
            return .number
        case .string, .rawJSON: return .rawJSON
        }
    }

    func encode(_ text: String, variable: String) throws -> (String, Bool) {
        switch self {
        case .string: return (text, false)
        case .number:
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw VariableInputError.invalidJSON(variable)
            }
            return (text, true)
        case .boolean:
            guard text == "true" || text == "false" else { throw VariableInputError.invalidJSON(variable) }
            return (text, true)
        case .rawJSON:
            guard let data = text.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                throw VariableInputError.invalidJSON(variable)
            }
            return (text, true)
        }
    }
}

@MainActor
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
    @Published var isRemembered = false
    @Published var rememberedSecretUnavailable = false
    @Published var rememberedSecretID: String?
    @Published var declaration: TerraformDeclaredInput?
    @Published var discoveredSource: String?
    @Published var hasUnresolvedDiscoveredValue = false
    @Published var unresolvedSource: String?

    var isMissingRequiredInput: Bool {
        declaration?.required == true && !isUserInput && discoveredSource == nil && !hasUnresolvedDiscoveredValue
    }

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

    func validate() throws { _ = try terraformJSONValue() }

    var validationError: String? {
        do { _ = try terraformJSONValue(); return nil }
        catch { return error.localizedDescription }
    }
}

@MainActor
class EnvironmentVariable: ObservableObject {
    var id = UUID()
    @Published var key: String = ""
    @Published var value: String = ""
    @Published var description: String = ""
    @Published var sensitive = false
    @Published var isUserInput = false
    @Published var isRemembered = false
    @Published var rememberedSecretUnavailable = false
    @Published var rememberedSecretID: String?

    func validate() throws {
        guard !key.isEmpty, !key.contains("="), !key.contains("\0") else {
            throw VariableInputError.invalidEnvironmentKey(key)
        }
        guard !value.contains("\0") else { throw VariableInputError.invalidEnvironmentValue(key) }
    }

    var validationError: String? {
        do { try validate(); return nil }
        catch { return error.localizedDescription }
    }
}
