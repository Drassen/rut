import SwiftUI
import MapKit

/// Stacking order for SwiftUI `Annotation`s on the map (higher = on top).
///
/// SwiftUI's `Map` has no z-order API for annotations and does not stack them in
/// declaration order. MapKit orders annotation views with equal `zPriority` by
/// latitude (southern views in front), so without explicit priorities two
/// overlapping markers swap order depending on which one lies further south.
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

extension View {
    /// Sets `zPriority` on the `MKAnnotationView` hosting this annotation content.
    /// Re-applied whenever MapKit (re)attaches the view, so recycled views keep their order.
    func mapAnnotationZ(_ priority: Float) -> some View {
        background(MapAnnotationZProbe(priority: priority).allowsHitTesting(false))
    }
}

private struct MapAnnotationZProbe: UIViewRepresentable {
    let priority: Float

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.priority = priority
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.priority = priority
    }

    final class ProbeView: UIView {
        var priority: Float = 0 {
            didSet { if priority != oldValue { apply() } }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let annotationView = view as? MKAnnotationView {
                    if annotationView.zPriority.rawValue != priority {
                        annotationView.zPriority = MKAnnotationViewZPriority(rawValue: priority)
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
