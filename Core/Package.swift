// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DictationCore", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "DictationCore", targets: ["DictationCore"])], targets: [.target(name: "DictationCore", swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"], swiftSettings: [.swiftLanguageMode(.v5)])])
