// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DictationAudio", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "DictationAudio", targets: ["DictationAudio"])],
    targets: [.target(name: "DictationAudio"), .testTarget(name: "DictationAudioTests", dependencies: ["DictationAudio"])],
    swiftLanguageModes: [.v5])
