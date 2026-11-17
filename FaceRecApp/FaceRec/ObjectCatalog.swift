import Foundation

/// The 80 kinds of object the detector knows, grouped for the filter list.
enum ObjectCatalog {
    struct Group: Identifiable {
        let name: String
        let symbol: String
        let labels: [String]
        var id: String { name }
    }

    static let groups: [Group] = [
        Group(name: "People", symbol: "person.fill", labels: ["person"]),
        Group(name: "Vehicles", symbol: "car.fill",
              labels: ["bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat"]),
        Group(name: "Animals", symbol: "pawprint.fill",
              labels: ["bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe"]),
        Group(name: "Bags and accessories", symbol: "bag.fill",
              labels: ["backpack", "umbrella", "handbag", "tie", "suitcase"]),
        Group(name: "Street", symbol: "signpost.right.fill",
              labels: ["traffic light", "fire hydrant", "stop sign", "parking meter", "bench"]),
        Group(name: "Electronics", symbol: "desktopcomputer",
              labels: ["tv", "laptop", "mouse", "remote", "keyboard", "cell phone"]),
        Group(name: "Furniture", symbol: "sofa.fill",
              labels: ["chair", "couch", "potted plant", "bed", "dining table", "toilet"]),
        Group(name: "Kitchen", symbol: "fork.knife",
              labels: ["bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl",
                       "microwave", "oven", "toaster", "sink", "refrigerator"]),
        Group(name: "Food", symbol: "carrot.fill",
              labels: ["banana", "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake"]),
        Group(name: "Sports", symbol: "figure.run",
              labels: ["frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove",
                       "skateboard", "surfboard", "tennis racket"]),
        Group(name: "Other", symbol: "square.grid.2x2.fill",
              labels: ["book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"]),
    ]

    static let all: Set<String> = Set(groups.flatMap(\.labels))

    /// What matters on a security camera: people, vehicles, pets and bags.
    static let security: Set<String> = Set(groups[0].labels + groups[1].labels
        + ["cat", "dog", "bird", "backpack", "handbag", "suitcase"])
}
