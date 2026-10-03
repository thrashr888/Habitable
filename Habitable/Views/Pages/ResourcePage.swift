//
//  ResourcePage.swift
//  Habitable
//

import AppKit
import SwiftUI

struct ShowResourceView: View {
    var resource: ShowResource
    @State private var searchText = ""

    private var attributes: [ResourceAttribute] {
        resourceAttributes(values: resource.values, sensitiveValues: resource.sensitiveValues)
    }

    private var filteredAttributes: [ResourceAttribute] {
        guard !searchText.isEmpty else { return attributes }
        return attributes.filter { $0.searchableText.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                if let address = resource.address {
                    GridRow(alignment: .top) {
                        Text("Address").foregroundStyle(.secondary)
                        Text(address)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let provider = resource.provider_name {
                    GridRow(alignment: .top) {
                        Text("Provider").foregroundStyle(.secondary)
                        if let url = terraformProviderRegistryURL(provider) {
                            Link(provider, destination: url)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(provider).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let mode = resource.mode { metadataRow("Mode", value: mode) }
                if let type = resource.type { metadataRow("Type", value: type) }
                if let name = resource.name { metadataRow("Name", value: name) }
                if let version = resource.schema_version { metadataRow("Schema version", value: String(version)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            HStack {
                Text("Attributes").font(.headline)
                Spacer()
                Text("\(filteredAttributes.count)").foregroundStyle(.secondary)
            }
            if !attributes.isEmpty {
                TextField("Search attributes", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            if filteredAttributes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: searchText.isEmpty ? "list.bullet.rectangle" : "magnifyingglass")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "No attributes" : "No matches").font(.headline)
                    Text(searchText.isEmpty ? "This resource has no recorded values." : "Try another search.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredAttributes) { attribute in
                    HStack(alignment: .top, spacing: 12) {
                        Text(attribute.path)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(minWidth: 150, alignment: .leading)
                        Text(attribute.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(attribute.value, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy value")
                        .accessibilityLabel("Copy value for \(attribute.path)")
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
        .padding()
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity, alignment: .topLeading)
    }
    private func metadataRow(_ label: String, value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ShowView: View {
    @State var show: ShowMessage

    var body: some View {
        VStack(alignment: .leading) {
            if !show.root_module.resources.isEmpty {
                Text("Resources").fontWeight(.bold)
                List(show.root_module.resources, id: \.id) { resource in
                    ShowResourceView(resource: resource)
                }
            }
            if !show.values.outputs.isEmpty {
                Text("Outputs").fontWeight(.bold)
                OutputView(outputs: show.values.outputs)
            }
        }
    }
}

struct ShowModuleView: View {
    @State var run: TerraformRun
    var body: some View { Text("id: \(run.id)") }
}
