// swift-tools-version: 6.2
// Only for `swift test`; the app itself is built with build.sh (Xcode project).
import PackageDescription

let package = Package(
    name: "ubiquitas",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sovrin/paritas", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(name: "ubiquitas", dependencies: [.product(name: "Paritas", package: "paritas")],
                          path: "ubiquitas", exclude: ["Assets.xcassets"]),
        .testTarget(name: "ubiquitasTests", dependencies: ["ubiquitas"]),
    ],
    swiftLanguageModes: [.v5]
)
