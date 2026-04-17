// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "RailCommerce",
    platforms: [.macOS(.v12), .iOS(.v16)],
    products: [
        .library(name: "RailCommerce", targets: ["RailCommerce"]),
        .executable(name: "RailCommerceDemo", targets: ["RailCommerceDemo"]),
        // iOS UIKit app layer — compiled only when UIKit is available.
        .library(name: "RailCommerceApp", targets: ["RailCommerceApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/ReactiveX/RxSwift.git", .upToNextMinor(from: "6.6.0")),
        .package(url: "https://github.com/realm/realm-swift.git", .upToNextMajor(from: "10.45.0"))
    ],
    targets: [
        .target(
            name: "RailCommerce",
            dependencies: [
                .product(name: "RxSwift", package: "RxSwift"),
                .product(name: "RealmSwift", package: "realm-swift",
                         condition: .when(platforms: [.iOS]))
            ],
            path: "Sources/RailCommerce"
        ),
        .target(
            name: "RailCommerceApp",
            dependencies: [
                "RailCommerce",
                .product(name: "RxSwift", package: "RxSwift"),
                .product(name: "RealmSwift", package: "realm-swift")
            ],
            path: "Sources/RailCommerceApp",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "RailCommerceDemo",
            dependencies: ["RailCommerce"],
            path: "Sources/RailCommerceDemo"
        ),
        .testTarget(
            name: "RailCommerceTests",
            dependencies: [
                "RailCommerce",
                .product(name: "RxSwift", package: "RxSwift")
            ],
            path: "Tests/RailCommerceTests"
        )
    ]
)
