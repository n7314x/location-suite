// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocationSuiteRouteEngine",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RouteEngine", targets: ["RouteEngine"])
    ],
    targets: [
        .target(
            name: "RouteEngine",
            path: "TLocation/Route"
        ),
        .testTarget(
            name: "RouteEngineTests",
            dependencies: ["RouteEngine"],
            path: "TLocationTests",
            exclude: ["TLocationTests.swift"],
            sources: ["RouteEngineTests.swift"]
        )
    ]
)
