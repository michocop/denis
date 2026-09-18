// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EnergyCourtage",
    // macOS is declared even though this ships as an iOS app. A package that
    // names only iOS gets the toolchain's ancient default minimum for every
    // other platform, so anything xcodebuild compiles for macOS is checked
    // against macOS 10.13 -- which is why Date.now, Task and Task.sleep(for:)
    // were all reported unavailable in code that only ever runs on a phone.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EnergyCourtage", targets: ["EnergyCourtage"])
    ],
    targets: [
        .target(name: "EnergyCourtage"),
        .testTarget(name: "EnergyCourtageTests", dependencies: ["EnergyCourtage"])
    ]
)
