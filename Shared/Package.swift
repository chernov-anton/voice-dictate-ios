// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DictationShared", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "DictationShared", targets: ["DictationShared"])], targets: [.target(name: "DictationShared"), .testTarget(name: "DictationSharedTests", dependencies: ["DictationShared"])])
