import XCTest
@testable import HabitableCore

final class ResourceMapTests: XCTestCase {
    private let classifier = ResourceMapClassifier()
    private func r(_ type: String, _ name: String = "main", module: String = "", deps: [String] = []) -> MapResource {
        MapResource(address: (module.isEmpty ? "" : module + ".") + type + "." + name,
                    type: type, name: name, module: module, dependencies: deps)
    }

    func testProviderCategoriesAndOverrides() {
        XCTAssertEqual(ResourceMapCategories.values.count, 3997)
        for (type, kind) in [("aws_s3_bucket", MapKind.data), ("aws_lambda_function", .appsAndAI),
                             ("aws_sqs_queue", .messaging), ("aws_iam_role", .identityAndMonitoring),
                             ("google_compute_network", .network), ("google_compute_backend_service", .frontDoor),
                             ("aws_eip", .network),
                             ("kubernetes_secret", .appsAndAI), ("helm_release", .appsAndAI),
                             ("custom_bucket", .data), ("custom_mystery", .other)] {
            XCTAssertEqual(classifier.kind(for: type), kind, type)
        }
    }

    func testFacetPrefersExplicitParentOverCloserLexicalAnchor() throws {
        let bucket = r("aws_s3_bucket", "storage")
        let function = r("aws_lambda_function", "aaa")
        let facet = r("aws_s3_bucket_versioning", "storage", deps: [bucket.address, function.address])
        let map = try classifier.classify([function, facet, bucket])
        XCTAssertEqual(map.tiles.first { $0.id == bucket.address }?.resources, [bucket.address, facet.address].sorted())
    }

    func testNearestHelperAndStableTieBreaking() throws {
        let a = r("aws_lambda_function", "alpha"), b = r("aws_lambda_function", "beta")
        let helper = r("aws_iam_role", deps: [b.address, a.address])
        let map = try classifier.classify([a, b, helper])
        XCTAssertTrue(map.tiles.first { $0.id == a.address }!.resources.contains(helper.address))
        XCTAssertEqual(map, try classifier.classify([helper, b, a]))
    }

    func testModuleInstancesAndKindsDoNotMergeByName() throws {
        let resources = [r("aws_s3_bucket", "chat_api", module: "module.service[\"one\"]"),
                         r("aws_s3_bucket", "chat_api", module: "module.service[\"two\"]"),
                         r("aws_lambda_function", "chat_api", module: "module.service[\"one\"]")]
        XCTAssertEqual(try classifier.classify(resources).tiles.count, 3)
    }

    func testGenericNamesRemainSeparateAndSemanticStemsMerge() throws {
        XCTAssertEqual(try classifier.classify([r("aws_s3_bucket"), r("aws_db_instance")]).tiles.count, 2)
        XCTAssertEqual(try classifier.classify([r("aws_s3_bucket", "chat_data_primary"), r("aws_s3_bucket", "chat_data_secondary")]).tiles.count, 1)
    }

    func testAWSWorkloadSupportOwnershipAndProviderNeutralFallback() throws {
        let asg = r("aws_autoscaling_group", "rookery")
        let launch = r("aws_launch_template", "rookery", deps: [asg.address])
        let role = r("aws_iam_role", "rookery", deps: [asg.address])
        let security = r("aws_security_group", "rookery", deps: [asg.address])
        let database = r("aws_db_instance", "rookery", deps: ["aws_db_subnet_group.rookery"])
        let dbSubnets = r("aws_db_subnet_group", "rookery", deps: [database.address])
        let cache = r("aws_elasticache_cluster", "rookery", deps: ["aws_elasticache_subnet_group.rookery"])
        let cacheSubnets = r("aws_elasticache_subnet_group", "rookery", deps: [cache.address])
        let cert = r("aws_acm_certificate", "rookery")
        let cdn = r("aws_cloudfront_distribution", "rookery")
        let dns = r("aws_route53_zone", "rookery")
        let email = r("aws_ses_domain_identity", "rookery")
        let bucket = r("aws_s3_bucket", "rookery")
        let vpc = r("aws_vpc", "rookery", module: "module.network")
        let eip = r("aws_eip", "rookery", module: "module.address")
        let github = r("github_repository", "rookery")
        let monitor = r("datadog_monitor", "rookery")

        let map = try classifier.classify([asg, launch, role, security, database, dbSubnets,
                                           cache, cacheSubnets, cert, cdn, dns, email, bucket,
                                           github, monitor, vpc, eip])
        func tile(containing address: String) throws -> MapTile {
            try XCTUnwrap(map.tiles.first { $0.resources.contains(address) })
        }
        XCTAssertEqual(try tile(containing: asg.address).kind, .appsAndAI)
        XCTAssertEqual(try tile(containing: launch.address).id, asg.address)
        XCTAssertEqual(try tile(containing: role.address).id, asg.address)
        XCTAssertEqual(try tile(containing: security.address).id, asg.address)
        XCTAssertEqual(try tile(containing: dbSubnets.address).id, database.address)
        XCTAssertEqual(try tile(containing: cacheSubnets.address).id, cache.address)
        XCTAssertNotEqual(try tile(containing: database.address).id, try tile(containing: cache.address).id)
        XCTAssertEqual(try tile(containing: github.address).kind, .other)
        XCTAssertEqual(try tile(containing: monitor.address).kind, .other)
        XCTAssertTrue([cert, cdn, dns, email, bucket].allSatisfy { resource in
            (try? tile(containing: resource.address).title.contains("·")) == true
        })
        XCTAssertEqual(try tile(containing: cert.address).title, "Rookery · Certificate")
        XCTAssertEqual(try tile(containing: cdn.address).title, "Rookery · CDN")
        XCTAssertEqual(try tile(containing: dns.address).title, "Rookery · DNS")
        XCTAssertEqual(try tile(containing: email.address).title, "Rookery · SES domain")
        XCTAssertEqual(try tile(containing: bucket.address).title, "Rookery · Bucket")
        XCTAssertEqual(try tile(containing: vpc.address).title, "Rookery · Network")
        XCTAssertEqual(try tile(containing: eip.address).title, "Rookery · Network")
        XCTAssertEqual(Set(map.tiles.flatMap(\.resources)).count, 17)
    }

    func testAllResourcesAccountedForIncludingUnknownAndData() throws {
        let unknown = r("acme_widget"), role = r("aws_iam_role")
        let data = MapResource(address: "data.aws_region.current", type: "aws_region", name: "current", isData: true)
        let map = try classifier.classify([unknown, role, data])
        XCTAssertEqual(map.tiles.map(\.kind), [.identityAndMonitoring, .other])
        XCTAssertEqual(map.tiles.flatMap(\.resources).sorted(), [unknown.address, role.address].sorted())
        XCTAssertEqual(map.dataSources, [data.address])
    }

    func testThreeHopLimitAndCyclesTerminate() throws {
        let anchor = r("aws_lambda_function")
        let h1 = r("aws_iam_role", "h1", deps: [anchor.address])
        let h2 = r("aws_iam_role", "h2", deps: [h1.address])
        let h3 = r("aws_iam_role", "h3", deps: [h2.address])
        let h4 = r("aws_iam_role", "h4", deps: [h3.address, "aws_iam_role.h5"])
        let h5 = r("aws_iam_role", "h5", deps: [h4.address])
        let map = try classifier.classify([h5, h4, h3, h2, h1, anchor])
        XCTAssertEqual(map.tiles.first { $0.id == anchor.address }?.resources.count, 4)
        XCTAssertEqual(map.tiles.count, 3)
    }

    func testRawStateStacksKeysAndDependencies() throws {
        let state = #"""
        {"version":4,"resources":[
          {"mode":"managed","module":"module.app[\"east\"]","type":"aws_lambda_function","name":"main","instances":[
            {"index_key":"a.b\"c","dependencies":["aws_iam_role.main"],"attributes":{"password":"do not retain"}},
            {"index_key":2,"dependencies":["aws_iam_role.main"]},
            {"index_key":2,"deposed":"old","attributes":{}}]},
          {"mode":"managed","type":"aws_iam_role","name":"main","instances":[{}]}]}
        """#
        let resources = try ResourceMapStateReader.read(Data(state.utf8))
        XCTAssertEqual(resources.count, 3)
        XCTAssertTrue(resources.contains { $0.address == #"module.app["east"].aws_lambda_function.main["a.b\"c"]"# })
        let map = try classifier.classify(resources)
        XCTAssertEqual(map.tiles.count, 1)
        XCTAssertEqual(map.tiles[0].anchors.count, 2)
        XCTAssertEqual(map.tiles[0].resources.count, 3)
    }

    func testBlockDependenciesResolveInstancesAndKeepConnectionsDirected() throws {
        let a = MapResource(address: "aws_s3_bucket.main[0]", type: "aws_s3_bucket", name: "main")
        let b = MapResource(address: "aws_s3_bucket.main[1]", type: "aws_s3_bucket", name: "main")
        let app = r("aws_lambda_function", deps: ["aws_s3_bucket.main"])
        let map = try classifier.classify([a, app, b])
        XCTAssertEqual(map.connections, [MapConnection(source: app.address, target: a.address)])
    }

    func testShowJSONNestedModulesDoesNotInventDependencies() throws {
        let json = #"""
        {"format_version":"1.0","values":{"root_module":{"child_modules":[
          {"address":"module.app","resources":[{"address":"module.app.aws_s3_bucket.main","mode":"managed","type":"aws_s3_bucket","name":"main","values":{"id":"secret"}}]}
        ]}}}
        """#
        let result = try ResourceMapStateReader.read(Data(json.utf8))
        XCTAssertEqual(result, [r("aws_s3_bucket", module: "module.app")])
        XCTAssertEqual(try ResourceMapStateReader.read(Data(#"{"format_version":"1.0","values":{"outputs":{}}}"#.utf8)), [])
    }

    func testInvalidAndDuplicateStateFailsExplicitly() throws {
        for json in [#"{}"#, #"{"version":4,"resources":[{}]}"#,
                     #"{"format_version":"1.0","values":{"root_module":{"resources":{}}}}"#,
                     #"{"format_version":"1.0","values":{"root_module":[]}}"#] {
            XCTAssertThrowsError(try ResourceMapStateReader.read(Data(json.utf8)))
        }
        XCTAssertThrowsError(try classifier.classify([r("aws_s3_bucket"), r("aws_s3_bucket")]))
    }

    func testThousandResourcesAreDeterministicAndFullyAccountedFor() throws {
        let resources = (0..<1000).map { r("aws_s3_bucket", "bucket\($0)") }
        let start = ContinuousClock.now
        let map = try classifier.classify(resources)
        print("Resource map 1000-resource classification: \(start.duration(to: .now))")
        XCTAssertEqual(map.tiles.count, 1000)
        XCTAssertEqual(map, try classifier.classify(resources.reversed()))
        XCTAssertEqual(Set(map.tiles.flatMap(\.resources)).count, 1000)
    }

    func testCanvasLayoutContainsTilesWithoutOverlapAndWrapsRows() {
        let tiles = (0..<9).map { index in
            MapTile(id: "tile-\(index)", title: "Tile \(index)", kind: .data,
                    anchors: [], resources: [])
        }
        let layout = MapCanvasLayout(map: ResourceMap(tiles: tiles, connections: [], dataSources: []), width: 680)

        XCTAssertEqual(layout.width, 680)
        XCTAssertGreaterThan(layout.height, 0)
        XCTAssertEqual(layout.tiles.count, tiles.count)
        for tile in layout.tiles {
            XCTAssertGreaterThanOrEqual(tile.x, 28)
            XCTAssertGreaterThanOrEqual(tile.y, 0)
            XCTAssertLessThanOrEqual(tile.x + tile.width, layout.width - 28)
            XCTAssertLessThanOrEqual(tile.y + tile.height, layout.height)
            XCTAssertTrue(layout.bands.contains {
                $0.kind == .data && tile.y >= $0.y && tile.y + tile.height <= $0.y + $0.height
            })
        }
        for (index, first) in layout.tiles.enumerated() {
            for second in layout.tiles.dropFirst(index + 1) {
                let overlapsHorizontally = first.x < second.x + second.width && second.x < first.x + first.width
                let overlapsVertically = first.y < second.y + second.height && second.y < first.y + first.height
                XCTAssertFalse(overlapsHorizontally && overlapsVertically, "\(first.id) overlaps \(second.id)")
            }
        }
        XCTAssertEqual(Set(layout.tiles.map(\.y)).count, 5)
    }

    func testCanvasLayoutIsDeterministicForPermutedTilesAndConnections() {
        let tiles = [
            MapTile(id: "a", title: "A", kind: .appsAndAI, anchors: [], resources: []),
            MapTile(id: "b", title: "B", kind: .appsAndAI, anchors: [], resources: []),
            MapTile(id: "c", title: "C", kind: .data, anchors: [], resources: []),
            MapTile(id: "d", title: "D", kind: .other, anchors: [], resources: [])
        ]
        let connections = [MapConnection(source: "a", target: "b"), MapConnection(source: "c", target: "a")]
        let first = MapCanvasLayout(map: ResourceMap(tiles: tiles, connections: connections, dataSources: []), width: 920)
        let permuted = MapCanvasLayout(map: ResourceMap(tiles: tiles.reversed(), connections: connections.reversed(), dataSources: []), width: 920)
        XCTAssertEqual(first, permuted)
        let idsByBand = Dictionary(grouping: first.tiles, by: { $0.y }).values.map { $0.map(\.id) }
        XCTAssertEqual(idsByBand.first(where: { $0.contains("a") }), ["a", "b"])
    }

    func testCanvasLayoutOrdersDependenciesAndFallsBackLexicallyForCycles() {
        let tiles = ["z", "b", "a", "c"].map {
            MapTile(id: $0, title: $0, kind: .data, anchors: [], resources: [])
        }
        let map = ResourceMap(tiles: tiles,
                              connections: [MapConnection(source: "b", target: "a"),
                                             MapConnection(source: "a", target: "b"),
                                             MapConnection(source: "c", target: "z")],
                              dataSources: [])
        let layout = MapCanvasLayout(map: map, width: 1000)
        XCTAssertEqual(layout.tiles.map(\.id), ["c", "z", "a", "b"])
    }

    func testCanvasLayoutOmitsAllEmptyBands() {
        let layout = MapCanvasLayout(map: ResourceMap(tiles: [], connections: [], dataSources: []), width: 300)
        XCTAssertEqual(layout.width, 580)
        XCTAssertTrue(layout.bands.isEmpty)
        XCTAssertEqual(layout.height, 0)
        XCTAssertTrue(layout.tiles.isEmpty)

        let withOther = MapCanvasLayout(
            map: ResourceMap(tiles: [MapTile(id: "mystery", title: "Mystery", kind: .other, anchors: [], resources: [])],
                             connections: [], dataSources: []),
            width: 680
        )
        XCTAssertEqual(withOther.bands.map(\.kind), [.other])
        XCTAssertEqual(withOther.bands.first?.y, 0)
        XCTAssertEqual(withOther.bands.last?.height, 170)
    }

    func testWorkspaceReferencesUseOnlyExplicitRemoteStateDependencies() throws {
        let west = MapResource(address: #"data.terraform_remote_state.shared["west"]"#,
                               type: "terraform_remote_state", name: "shared", isData: true)
        let east = MapResource(address: #"data.terraform_remote_state.shared["east"]"#,
                               type: "terraform_remote_state", name: "shared", isData: true)
        let unused = MapResource(address: "data.tfe_outputs.unused", type: "tfe_outputs",
                                 name: "unused", isData: true)
        let unrelated = MapResource(address: "data.aws_region.current", type: "aws_region",
                                    name: "current", isData: true)
        let direct = r("aws_lambda_function", "direct", deps: [west.address])
        let block = r("aws_lambda_function", "block", deps: ["data.terraform_remote_state.shared"])
        let input = [west, east, unused, unrelated, direct, block]

        let map = try classifier.classify(input)
        let tileForName: [String: String] = Dictionary(uniqueKeysWithValues: map.tiles.flatMap { tile in
            tile.resources.compactMap { address -> (String, String)? in
                guard address == direct.address || address == block.address else { return nil }
                return (address, tile.id)
            }
        })
        XCTAssertEqual(map.workspaceReferences, [
            MapWorkspaceReference(address: #"data.terraform_remote_state.shared["east"]"#,
                                  name: "shared", consumers: [tileForName[block.address]!]),
            MapWorkspaceReference(address: #"data.terraform_remote_state.shared["west"]"#,
                                  name: "shared", consumers: [tileForName[block.address]!, tileForName[direct.address]!].sorted()),
            MapWorkspaceReference(address: "data.tfe_outputs.unused", name: "unused", consumers: [])
        ])
        XCTAssertFalse(map.workspaceReferences.contains { $0.address == unrelated.address })

        let permuted = try classifier.classify(input.reversed())
        XCTAssertEqual(map.workspaceReferences, permuted.workspaceReferences)
    }

    func testWorkspaceReferencesRespectModuleQualifiedDataBlocksAndDoNotInventConsumers() throws {
        let source = MapResource(address: #"module.shared.data.terraform_remote_state.base[0]"#,
                                 type: "terraform_remote_state", name: "base",
                                 module: "module.shared", isData: true)
        let wrongModule = MapResource(address: "module.other.data.terraform_remote_state.base[0]",
                                      type: "terraform_remote_state", name: "base",
                                      module: "module.other", isData: true)
        let consumer = r("aws_s3_bucket", "app", module: "module.shared",
                         deps: ["module.shared.data.terraform_remote_state.base"])
        let unrelated = r("aws_lambda_function", "unrelated")
        let map = try classifier.classify([wrongModule, unrelated, consumer, source])
        let consumerTile = try XCTUnwrap(map.tiles.first { $0.resources.contains(consumer.address) }?.id)
        let unrelatedTile = try XCTUnwrap(map.tiles.first { $0.resources.contains(unrelated.address) }?.id)

        XCTAssertEqual(map.workspaceReferences, [
            MapWorkspaceReference(address: "module.other.data.terraform_remote_state.base[0]",
                                  name: "base", consumers: []),
            MapWorkspaceReference(address: #"module.shared.data.terraform_remote_state.base[0]"#,
                                  name: "base", consumers: [consumerTile])
        ])
        XCTAssertFalse(map.workspaceReferences.contains { $0.consumers.contains(unrelatedTile) })
    }
}
