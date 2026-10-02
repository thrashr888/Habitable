//
//  Resource.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/14/21.
//

import SwiftUI

struct ShowResourceView: View {
    var resource: ShowResource
    
    var providerLink: URL? {
        if let provider_name = resource.provider_name {
            return URL(string: "https://\(provider_name)")!
        }
        return nil
    }
    
//    var id = UUID()
//    var address: String?
//    var mode: String?
//    var type: String?
//    var name: String?
//    var provider_name: String?
//    var schema_version: Int?
    
    var body: some View {
        VStack(alignment: .leading) {
            if let name = resource.name {
                Text("Name")
                    .font(.headline)
                Text("\"\(name)\"")
            }
            if let address = resource.address {
                Text("Address")
                    .font(.headline)
                    .padding(.top)
                Text("\(address)")
                    .font(.system(.body, design: .monospaced))
            }
            if let mode = resource.mode {
                Text("Mode")
                    .font(.headline)
                    .padding(.top)
                Text("\(mode)")
            }
            if let type = resource.type {
                Text("Type")
                    .font(.headline)
                    .padding(.top)
                Text("\(type)")
            }
            if let pl = providerLink {
                Text("Provider name")
                    .font(.headline)
                    .padding(.top)
                Link(pl.absoluteString, destination: pl)
                    .padding(0)
                    .foregroundColor(.accentColor)
            }
//            if resource.values != nil {
//                Text("\(resource.values!)")
//            }
            Spacer()
        }
        .padding(.all)
    }
}

struct ShowView: View {
    @State var show: ShowMessage

    var body: some View {
        VStack(alignment: .leading) {
            if show.root_module.resources.count > 0 {
                Text("Resources")
                    .fontWeight(.bold)
                List(show.root_module.resources, id: \.id) { resource in
                    ShowResourceView(resource: resource)
                }
            }
            if show.values.outputs.count > 0 {
                Text("Outputs")
                    .fontWeight(.bold)
                OutputView(outputs: show.values.outputs)
            }
        }
    }
}

struct ShowModuleView: View {
    @State var run: TerraformRun
    var body: some View {
        Text("id: \(run.id)")
    }
}
