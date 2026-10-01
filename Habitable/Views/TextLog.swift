//
//  Text.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/9/21.
//

import SwiftUI

struct TextLogView: View {
    let text: String
//    @State var term = SwiftTerm.TerminalView()
//
//    init(text: String?, ansi: Text?){
//        if let t = text {
//            self.term.send(txt: t)
//        }
//    }
//
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
        .background(.background)
    }

}

struct TextLogView_Previews: PreviewProvider {
    static var previews: some View {
        TextLogView(text: """
        Initializing the backend...

        Initializing provider plugins...
        - Reusing previous version of hashicorp/random from the dependency lock file
        - Using previously-installed hashicorp/random v3.1.0

        Terraform has been successfully initialized!

        You may now begin working with Terraform. Try running "terraform plan" to see
        any changes that are required for your infrastructure. All Terraform commands
        should now work.

        If you ever set or change modules or backend configuration for Terraform,
        rerun this command to reinitialize your working directory. If you forget, other
        commands will detect it and remind you to do so if necessary.
        """)
    }
}
