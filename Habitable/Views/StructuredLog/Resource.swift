//
//  Resource.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/13/21.
//

import SwiftUI

struct ResourceView: View {
    var resourceState: ResourceState
    var resource: Resource {
        resourceState.resource
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("\(resourceState.action.rawValue)")
                Text("\(resource.implied_provider ?? "terraform")")
                Text("\(resource.addr)")
            }
            ForEach(resourceState.stages, id: \.id) { stage in
                HStack {
                    Text("stage: \(stage.state.rawValue)")
                    if let identifier = stage.identifier {
                        Text("\(identifier)")
                    }
                    if let elapsed = stage.elapsed, elapsed > "0" {
                        Text("\(elapsed) seconds")
                    }
                    if stage.done {
                        Text("done")
                    }
                    if stage.errored {
                        Text("errored")
                    }
                }
            }
            Divider()
        }
    }
}
