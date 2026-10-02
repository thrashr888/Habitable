//
//  Resource.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/13/21.
//

import SwiftUI

struct ResourceView: View {
    @ObservedObject var resourceState: ResourceState
    var resource: Resource {
        resourceState.resource
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(resource.addr)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Text(resourceState.action.rawValue.capitalized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(resourceState.stages, id: \.id) { stage in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: stage.errored ? "exclamationmark.circle.fill" : (stage.done ? "checkmark.circle" : "clock"))
                            .foregroundStyle(stage.errored ? Color.red : Color.secondary)
                            .accessibilityHidden(true)
                        Text(stage.state.rawValue.capitalized)
                        Spacer()
                        if let elapsed = stage.elapsed, let seconds = Double(elapsed), seconds > 0 {
                            Text("\(elapsed)s").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if let identifier = stage.identifier {
                        Text(identifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}
