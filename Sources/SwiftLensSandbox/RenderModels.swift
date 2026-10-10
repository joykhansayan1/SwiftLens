import Foundation
import SwiftLensCore

/// Something renderable found in a snippet.
public struct PreviewEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// `#Preview { ... }`
        case previewMacro
        /// `struct X_Previews: PreviewProvider { static var previews: some View }`
        case previewProvider
        /// A `View` with a zero-argument initializer, used when a snippet has no explicit previews.
        case viewType
    }

    public var id: Int
    public var name: String
    public var kind: Kind
    public var span: SourceSpan
    public var traits: [PreviewTrait]
    /// `@Previewable` declarations (already lowered to plain property declarations, e.g. `@State var x = 0`).
    public var previewableDeclarations: [String]
    /// The statements of the preview body (for `#Preview`), or the expression creating the view.
    public var body: String
    /// First line of `body` in the original file, used for `#sourceLocation` so compiler errors point at the snippet.
    public var bodyLine: Int
    public var typeName: String?
}

/// Traits from `#Preview(traits: ...)`. SwiftLens honours layout traits; orientation traits swap the canvas size.
public enum PreviewTrait: Codable, Hashable, Sendable {
    case sizeThatFitsLayout
    case fixedLayout(width: Double, height: Double)
    case defaultLayout
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    case other(String)

    public var isLandscape: Bool {
        self == .landscapeLeft || self == .landscapeRight
    }
}

/// A canvas size preset.
public struct DevicePreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var width: Double
    public var height: Double

    public static let all: [DevicePreset] = [
        .init(name: "iPhone SE", width: 375, height: 667),
        .init(name: "iPhone 16", width: 393, height: 852),
        .init(name: "iPhone 16 Pro Max", width: 440, height: 956),
        .init(name: "iPad mini", width: 744, height: 1133),
        .init(name: "iPad Pro 13\"", width: 1032, height: 1376),
        .init(name: "Mac window", width: 800, height: 600),
        .init(name: "Apple Watch 46mm", width: 208, height: 248),
        .init(name: "Widget small", width: 170, height: 170),
        .init(name: "Widget medium", width: 364, height: 170),
    ]

    public static func named(_ name: String) -> DevicePreset? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// One environment configuration to render a preview in. A render request is a matrix of variants.
public struct RenderVariant: Codable, Hashable, Sendable, Identifiable {
    public enum Layout: String, Codable, Sendable {
        /// Use the view's ideal size (`.sizeThatFitsLayout`).
        case sizeThatFits
        /// Use `width` × `height`.
        case fixed
    }

    public enum Engine: String, Codable, Sendable {
        /// `NSHostingView` + `cacheDisplay`: renders AppKit-backed controls (buttons, lists, text fields).
        case appKit
        /// SwiftUI `ImageRenderer`: exact scale control, but skips platform-backed controls.
        case imageRenderer
    }

    public var id: String { label }
    public var label: String
    public var layout: Layout = .sizeThatFits
    public var width: Double? = nil
    public var height: Double? = nil
    public var colorScheme: String = "light"
    /// SwiftUI `DynamicTypeSize` case name (`xSmall` ... `accessibility5`).
    public var dynamicTypeSize: String = "large"
    public var locale: String? = nil
    /// `leftToRight` or `rightToLeft`.
    public var layoutDirection: String = "leftToRight"
    public var scale: Double = 2
    public var engine: Engine = .appKit
    /// Paint the platform window background behind the view (otherwise transparent).
    public var opaqueBackground: Bool = true

    public init(
        label: String,
        layout: Layout = .sizeThatFits,
        width: Double? = nil,
        height: Double? = nil,
        colorScheme: String = "light",
        dynamicTypeSize: String = "large",
        locale: String? = nil,
        layoutDirection: String = "leftToRight",
        scale: Double = 2,
        engine: Engine = .appKit,
        opaqueBackground: Bool = true
    ) {
        self.label = label
        self.layout = layout
        self.width = width
        self.height = height
        self.colorScheme = colorScheme
        self.dynamicTypeSize = dynamicTypeSize
        self.locale = locale
        self.layoutDirection = layoutDirection
        self.scale = scale
        self.engine = engine
        self.opaqueBackground = opaqueBackground
    }

    public static let validDynamicTypeSizes = [
        "xSmall", "small", "medium", "large", "xLarge", "xxLarge", "xxxLarge",
        "accessibility1", "accessibility2", "accessibility3", "accessibility4", "accessibility5",
    ]

    /// Applies preview traits on top of this variant (traits win over defaults, explicit sizes win over traits).
    public func applying(_ traits: [PreviewTrait]) -> RenderVariant {
        var copy = self
        for trait in traits {
            switch trait {
            case .sizeThatFitsLayout:
                if width == nil && height == nil { copy.layout = .sizeThatFits }
            case .fixedLayout(let w, let h):
                copy.layout = .fixed
                copy.width = w
                copy.height = h
            case .landscapeLeft, .landscapeRight:
                if let w = copy.width, let h = copy.height, h > w {
                    copy.width = h
                    copy.height = w
                }
            default:
                break
            }
        }
        return copy
    }

    /// Builds the cartesian product of the given dimensions, labelling each combination.
    public static func matrix(
        colorSchemes: [String] = ["light"],
        dynamicTypeSizes: [String] = ["large"],
        locales: [String?] = [nil],
        layoutDirections: [String] = ["leftToRight"],
        devices: [DevicePreset?] = [nil],
        engine: Engine = .appKit,
        scale: Double = 2
    ) -> [RenderVariant] {
        var variants: [RenderVariant] = []
        for device in devices {
            for scheme in colorSchemes {
                for size in dynamicTypeSizes {
                    for locale in locales {
                        for direction in layoutDirections {
                            var parts: [String] = []
                            if let device { parts.append(device.name) }
                            if colorSchemes.count > 1 || scheme != "light" { parts.append(scheme) }
                            if dynamicTypeSizes.count > 1 || size != "large" { parts.append(size) }
                            if let locale { parts.append(locale) }
                            if direction == "rightToLeft" { parts.append("RTL") }
                            variants.append(RenderVariant(
                                label: parts.isEmpty ? "default" : parts.joined(separator: " · "),
                                layout: device == nil ? .sizeThatFits : .fixed,
                                width: device?.width,
                                height: device?.height,
                                colorScheme: scheme,
                                dynamicTypeSize: size,
                                locale: locale,
                                layoutDirection: direction,
                                scale: scale,
                                engine: engine
                            ))
                        }
                    }
                }
            }
        }
        return variants
    }
}

/// A request handed to the out-of-process render agent.
public struct RenderJob: Codable, Sendable {
    public var libraryPath: String
    /// Preview indices to render; empty means all.
    public var previewIndices: [Int]
    public var variants: [RenderVariant]
    public var outputDirectory: String
    /// Per-preview traits, indexed like the library's previews.
    public var traits: [[PreviewTrait]]
    /// Seconds after which a single render is considered hung.
    public var timeout: Double

    public init(libraryPath: String, previewIndices: [Int] = [], variants: [RenderVariant], outputDirectory: String, traits: [[PreviewTrait]] = [], timeout: Double = 15) {
        self.libraryPath = libraryPath
        self.previewIndices = previewIndices
        self.variants = variants
        self.outputDirectory = outputDirectory
        self.traits = traits
        self.timeout = timeout
    }
}

/// Outcome of rendering one preview in one variant.
public struct RenderOutput: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(previewIndex)-\(variant.label)" }
    public var previewIndex: Int
    public var previewName: String
    public var variant: RenderVariant
    public var imagePath: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pointWidth: Double
    public var pointHeight: Double
    public var durationMilliseconds: Double
    public var error: String?

    public init(previewIndex: Int, previewName: String, variant: RenderVariant, imagePath: String?, pixelWidth: Int = 0, pixelHeight: Int = 0, pointWidth: Double = 0, pointHeight: Double = 0, durationMilliseconds: Double = 0, error: String? = nil) {
        self.previewIndex = previewIndex
        self.previewName = previewName
        self.variant = variant
        self.imagePath = imagePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.durationMilliseconds = durationMilliseconds
        self.error = error
    }
}

/// Full result of a render job.
public struct RenderReport: Codable, Sendable {
    public var outputs: [RenderOutput]
    public var compileDiagnostics: [LensDiagnostic]
    public var compileDurationMilliseconds: Double
    public var renderDurationMilliseconds: Double
    public var cacheHit: Bool
    /// Set when the agent crashed or timed out; the app stays alive regardless.
    public var agentFailure: String?

    public init(outputs: [RenderOutput] = [], compileDiagnostics: [LensDiagnostic] = [], compileDurationMilliseconds: Double = 0, renderDurationMilliseconds: Double = 0, cacheHit: Bool = false, agentFailure: String? = nil) {
        self.outputs = outputs
        self.compileDiagnostics = compileDiagnostics
        self.compileDurationMilliseconds = compileDurationMilliseconds
        self.renderDurationMilliseconds = renderDurationMilliseconds
        self.cacheHit = cacheHit
        self.agentFailure = agentFailure
    }
}
