/// Stacking order for map annotation views (`MKAnnotationView.zPriority`, higher = on top).
///
/// MapKit orders annotation views with equal `zPriority` by latitude (southern views in
/// front), so without explicit priorities two overlapping markers swap order depending on
/// which one lies further south.
enum MapAnnotationZ {
    /// Vector points in navigation mode — below all navigation markers.
    static let vectorPointBelow: Float = 100
    static let database: Float = 300
    static let inactiveRoute: Float = 400
    static let activeRoute: Float = 600
    /// Vector points in vector mode — above all navigation markers.
    static let vectorPointAbove: Float = 900
    static let insertGhost: Float = 950
}
