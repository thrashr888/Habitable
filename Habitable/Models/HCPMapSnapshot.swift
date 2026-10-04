import Foundation
import SwiftyJSON

/// Only already-redacted display strings leave the state decoder.
struct MapDisplayResource: Equatable, Sendable {
    let address: String
    let type: String
    let displayAttributes: [ResourceAttribute]
}

struct HCPMapSnapshot: Equatable, Sendable {
    let versionID: String
    let map: ResourceMap
    let resources: [MapDisplayResource]
    let notice: String?

    static func decode(versionID: String, raw: Data, shown: Data?) throws -> HCPMapSnapshot {
        let metadata = try ResourceMapStateReader.read(raw)
        let map = try ResourceMapClassifier().classify(metadata)
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
        return HCPMapSnapshot(versionID: versionID, map: map, resources: resources, notice: notice)
    }
}
