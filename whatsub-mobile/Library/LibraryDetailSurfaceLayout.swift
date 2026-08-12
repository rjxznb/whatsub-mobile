import CoreGraphics

struct LibraryDetailSurfaceLayout: Equatable {
    enum Geometry: Equatable { case portrait, landscape }

    let geometry: Geometry
    let playerSurfaceIdentity = "library-detail-player-surface"

    static func resolve(isLandscape: Bool) -> Self {
        Self(geometry: isLandscape ? .landscape : .portrait)
    }
}
