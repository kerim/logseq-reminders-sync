// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "logseq-reminders-sync",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "logseq-reminders-sync", targets: ["logseq-reminders-sync"]),
        .library(name: "SyncCore", targets: ["SyncCore"]),
    ],
    targets: [
        .target(
            name: "SyncCore",
            path: "Sources/SyncCore"
        ),
        .executableTarget(
            name: "logseq-reminders-sync",
            dependencies: ["SyncCore"],
            path: "Sources/logseq-reminders-sync",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/logseq-reminders-sync/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "SyncCoreTests",
            dependencies: ["SyncCore"],
            path: "Tests/SyncCoreTests"
        ),
    ]
)
