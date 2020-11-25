// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-deque",
    products: [
        .library(
            name: "Deque",
            targets: ["Deque"]),
    ],
    targets: [
        .target(
            name: "Deque",
            dependencies: []),
        .testTarget(
            name: "DequeTests",
            dependencies: ["Deque"]),
    ]
)
