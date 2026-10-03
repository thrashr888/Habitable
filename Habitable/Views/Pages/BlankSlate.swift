//
//  BlankSlate.swift
//  Habitable
//

import SwiftUI

struct BlankSlateView: View {
    let recentFolders: [URL]
    let onChooseFolder: () -> Void
    let onOpenRecent: (URL) -> Void

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open a Terraform folder")
                    .font(.largeTitle.weight(.semibold))
                Text("Open a local folder with Terraform configuration to inspect its runs, resources, outputs, and variables. Habitable can initialize it and create plans for you.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose Folder…", action: onChooseFolder)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Getting started").font(.headline)
                Label("Open a folder containing your .tf files.", systemImage: "folder")
                Label("Initialize Terraform in Habitable when prompted.", systemImage: "shippingbox")
                Label("Choose the Terraform workspace, then validate and plan.", systemImage: "square.stack.3d.up")
            }
            .foregroundStyle(.secondary)

            if !recentFolders.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Folders").font(.headline)
                    ForEach(recentFolders, id: \.path) { url in
                        Button { onOpenRecent(url) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
                                        .font(.body.weight(.medium))
                                    Spacer()
                                    if !FileManager.default.fileExists(atPath: url.path) {
                                        Text("Unavailable").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
        .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
