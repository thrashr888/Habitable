import XCTest
@testable import HabitableCore

final class AttentionModelTests: XCTestCase {
    private func workspace(_ name: String, status: String?, autoApply: Bool = false) -> HCPWorkspace {
        HCPWorkspace(id: "ws-\(name)", name: name, terraformVersion: nil, executionMode: "remote", locked: false, htmlURL: nil,
                     currentRunStatus: status, autoApply: autoApply)
    }
    private func explorer(_ name: String, drifted: Bool, count: Int) -> HCPExplorerWorkspace {
        HCPExplorerWorkspace(workspaceID: "ws-\(name)", workspaceName: name, projectName: nil, currentRunStatus: nil, currentRunAppliedAt: nil,
                             drifted: drifted, resourcesDrifted: count, resourcesUndrifted: nil, resourceCount: nil, terraformVersion: nil,
                             vcsRepoIdentifier: nil, tags: [], checksFailed: nil, checksErrored: nil, updatedAt: nil)
    }

    func testApprovalsThenRunsThenDrift() {
        let items = AttentionModel.items(
            workspaces: [workspace("zeta", status: "applying"), workspace("alpha", status: "planned"),
                         workspace("auto", status: "planned", autoApply: true), workspace("quiet", status: "applied")],
            explorer: ["quiet": explorer("quiet", drifted: true, count: 2), "alpha": explorer("alpha", drifted: false, count: 0)])
        XCTAssertEqual(items.map(\.id), ["approval:ws-alpha", "running:ws-zeta", "drift:ws-quiet"])
        XCTAssertEqual(items.first?.title, "Waiting for your approval")
        XCTAssertEqual(items.last?.title, "2 resources drifted")
    }
}
