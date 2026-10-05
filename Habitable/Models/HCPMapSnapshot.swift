import Foundation
import SwiftyJSON

/// Only already-redacted display strings leave the state decoder.
struct MapDisplayResource: Equatable, Sendable {
    let address: String
    let type: String
    let displayAttributes: [ResourceAttribute]
}

extension MapResource {
    /// Looks up a redacted display attribute by root key or `key[index]`, using the
    /// same JSON-quoted path encoding the attribute renderer produces.
    static func stateIdentity(type: String, displayAttributes: [ResourceAttribute]) -> String? {
        guard !displayAttributes.isEmpty else { return nil }
        return stateIdentity(type: type) { key, index in
            let encoded = (try? JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(key)\""
            let path = index.map { "\(encoded)[\($0)]" } ?? encoded
            guard let value = displayAttributes.first(where: { $0.path == path })?.value,
                  value != "(sensitive value)", value != "null" else { return nil }
            return value
        }
    }

    /// Attaches state identities for tile titles. Inventory fields are untouched, so
    /// snapshot comparisons that ignore identity still match.
    static func withIdentities(_ resources: [MapResource],
                               attributes: (String) -> [ResourceAttribute]?) -> [MapResource] {
        resources.map { resource in
            guard let found = attributes(resource.address),
                  let identity = stateIdentity(type: resource.type, displayAttributes: found) else { return resource }
            return MapResource(address: resource.address, type: resource.type, name: resource.name,
                               module: resource.module, isData: resource.isData,
                               dependencies: resource.dependencies, identity: identity)
        }
    }
}

struct HCPMapSnapshot: Equatable, Sendable {
    let versionID: String
    let map: ResourceMap
    let resources: [MapDisplayResource]
    let notice: String?
    let stateCreatedAt: Date?
    let stateSerial: Int?

    init(versionID: String, map: ResourceMap, resources: [MapDisplayResource], notice: String?,
         stateCreatedAt: Date? = nil, stateSerial: Int? = nil) {
        self.versionID = versionID
        self.map = map
        self.resources = resources
        self.notice = notice
        self.stateCreatedAt = stateCreatedAt
        self.stateSerial = stateSerial
    }

    static func decode(versionID: String, raw: Data, shown: Data?,
                       stateCreatedAt: Date? = nil, stateSerial: Int? = nil) throws -> HCPMapSnapshot {
        let metadata = try ResourceMapStateReader.read(raw)
        var details: [String: MapDisplayResource] = [:]
        var notice: String? = "Attribute details are unavailable for this state version. The map still shows its resources and connections."
        if let shown {
            let shownMetadata = try ResourceMapStateReader.read(shown)
            func inventory(_ resources: [MapResource]) -> [MapResource] {
                resources.map { MapResource(address: $0.address, type: $0.type, name: $0.name,
                                            module: $0.module, isData: $0.isData) }.sorted { $0.address < $1.address }
            }
            guard inventory(metadata) == inventory(shownMetadata) else { throw HCPViewerError.invalidResponse }
            let json = try JSON(data: shown)
            func collect(_ module: JSON) {
                for resource in module["resources"].arrayValue {
                    let address = resource["address"].stringValue
                    details[address] = MapDisplayResource(address: address, type: resource["type"].stringValue,
                        displayAttributes: resourceAttributes(values: resource["values"].dictionary,
                                                             sensitiveValues: resource["sensitive_values"]))
                }
                for child in module["child_modules"].arrayValue { collect(child) }
            }
            collect(json["values"]["root_module"])
            notice = nil
        }
        let resources = metadata.map {
            details[$0.address] ?? MapDisplayResource(address: $0.address, type: $0.type, displayAttributes: [])
        }
        let map = try ResourceMapClassifier().classify(
            MapResource.withIdentities(metadata) { details[$0]?.displayAttributes })
        return HCPMapSnapshot(versionID: versionID, map: map, resources: resources, notice: notice,
                              stateCreatedAt: stateCreatedAt, stateSerial: stateSerial)
    }
}
