//
//  ResourceListPage.swift
//  Habitable
//

import SwiftUI

/// The local workspace's List: the shared resource table fed from Terraform
/// state, the Map's tiles (for names and kinds) and the saved plan's actions.
struct ResourceListPage: View {
    @EnvironmentObject var workspace: Workspace
    /// The single selected address the window tracks (the Inspector follows it).
    @Binding var selection: String?
    var preview: MapChangePreview? = nil
    var onShowOnMap: ((String) -> Void)? = nil
    var onOpenSource: ((String) -> Void)? = nil
    @State private var selected: Set<String> = []

    private var displayResources: [MapDisplayResource] {
        (workspace.state?.resources ?? []).compactMap { resource in
            guard let address = resource.address, let type = resource.type else { return nil }
            return MapDisplayResource(address: address, type: type, displayAttributes: resource.displayAttributes,
                                      providerName: resource.provider_name)
        }
    }

    private var rows: [ResourceListRow] {
        var actions: [String: String] = [:]
        for (address, action) in preview?.resourceActions ?? [:] where action != .none {
            actions[address] = "\(action)"
        }
        return ResourceListBuilder.rows(resources: displayResources, tiles: preview?.map.tiles ?? workspace.resourceMap?.tiles ?? [],
                                        actions: actions, drifted: [])
    }

    var body: some View {
        ResourceTableView(rows: rows, selection: $selected,
                          isLoading: workspace.locked && workspace.state == nil,
                          emptyTitle: workspace.errorMessage == nil ? "No resources" : "Couldn’t read state",
                          emptyDetail: workspace.errorMessage ?? "Resources appear here after they are recorded in Terraform state.",
                          onShowOnMap: onShowOnMap,
                          onOpenReference: { row in
                              if let url = TerraformRegistryDocsModel.documentationURL(type: row.type, providerName: row.provider, mode: row.isDataSource ? "data" : "managed") {
                                  NSWorkspace.shared.open(url)
                              }
                          },
                          onOpenSource: onOpenSource)
        .onChange(of: selected) { ids in if ids.count == 1 { selection = ids.first } }
        .onAppear { if let selection { selected = [selection] } }
        .toolbar {
            QuietToolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: workspace.refreshResources) {
                        Label("Refresh", systemImage: "arrow.clockwise").help("Refresh state")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(workspace.locked)
                }
            }
        }
    }
}
