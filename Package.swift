// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Whispr",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Whispr", targets: ["Whispr"])
    ],
    targets: [
        .executableTarget(
            name: "Whispr",
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Whispr/Resources/Info.plist"
                ])
            ]
        )
    ]
)
