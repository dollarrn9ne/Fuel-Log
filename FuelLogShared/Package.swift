// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FuelLogShared",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "FuelLogShared",
            targets: ["FuelLogShared"]
        )
    ],
    targets: [
        .target(
            name: "FuelLogShared"
        )
    ]
)
