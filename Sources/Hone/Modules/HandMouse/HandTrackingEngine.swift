import Foundation

/// What turns a camera frame into the 21 hand joints. Persisted by raw value.
enum HandTrackingEngine: String, Codable, CaseIterable {
    /// Apple's hand pose request, on a crop around the hand.
    case vision
    /// Google's MediaPipe Hands (palm detector + landmark model) running in CoreML.
    case mediapipe
}
