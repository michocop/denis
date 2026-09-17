// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EnergyCourtage",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "EnergyCourtage", targets: ["EnergyCourtage"])
    ],
    targets: [
        .target(name: "EnergyCourtage"),
        .testTarget(name: "EnergyCourtageTests", dependencies: ["EnergyCourtage"])
    ]
)
