//
//  Text.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/9/21.
//

import SwiftUI

struct TextLogView: View {
    @State var text: String
//    @State var term = SwiftTerm.TerminalView()
//
//    init(text: String?, ansi: Text?){
//        if let t = text {
//            self.term.send(txt: t)
//        }
//    }
//
    var body: some View {
        VStack(alignment: .leading) {
            Text(text)
                .font(.system(.body, design: .monospaced))
        }
    }
}
