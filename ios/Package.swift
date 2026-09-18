// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EnergyCourtage",
    // iOS only, and deliberately so. Declaring macOS as well made the
    // availability errors go away and replaced them with SwiftUI ones
    // (navigationBarTitleDisplayMode and friends are iOS-only), which was the
    // clue: the answer is not to claim macOS support, it is to stop building
    // for macOS. CI pins -sdk iphonesimulator for exactly that reason.
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "EnergyCourtage", targets: ["EnergyCourtage"])
    ],
    targets: [
        .target(name: "EnergyCourtage"),
        .testTarget(name: "EnergyCourtageTests", dependencies: ["EnergyCourtage"])
    ]
)
