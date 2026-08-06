import AppKit
import SwiftUI
import WorkjetCore

struct ProviderLogo: View {
    let provider: ModelProvider
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(provider.fallbackMark)
                    .font(.system(size: size * 0.52, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.rawValue)-Logo")
        .accessibilityIdentifier(
            image == nil
                ? "provider.logo.fallback.\(provider.id)"
                : "provider.logo.brand.\(provider.id)"
        )
    }

    private var image: NSImage? {
        guard let url = Self.resourceURL(for: provider) else { return nil }
        return NSImage(contentsOf: url)
    }

    static func hasBrandArtwork(for provider: ModelProvider) -> Bool {
        guard let url = resourceURL(for: provider) else { return false }
        return NSImage(contentsOf: url) != nil
    }

    private static func resourceURL(for provider: ModelProvider) -> URL? {
        let bundles = resourceBundles
        let subdirectories: [String?] = [nil, "Providers", "Resources/Providers"]
        for bundle in bundles {
            for subdirectory in subdirectories {
                if let url = bundle.url(
                    forResource: provider.resourceName,
                    withExtension: "svg",
                    subdirectory: subdirectory
                ) {
                    return url
                }
            }
            if let resourcesURL = bundle.resourceURL {
                for relativePath in [
                    "\(provider.resourceName).svg",
                    "Providers/\(provider.resourceName).svg",
                    "Resources/Providers/\(provider.resourceName).svg",
                ] {
                    let url = resourcesURL.appendingPathComponent(relativePath)
                    if FileManager.default.fileExists(atPath: url.path) { return url }
                }
            }
        }
        return nil
    }

    /// SwiftPM places the resource bundle next to the executable while the
    /// release packager embeds it in `Contents/Resources`. Resolve both layouts
    /// without `Bundle.module`: its generated accessor contains the absolute
    /// build-machine path and must not be linked into a distributable app.
    private static var resourceBundles: [Bundle] {
        var bundles: [Bundle] = []
        var candidateURLs: [URL] = []
        if let resourcesURL = Bundle.main.resourceURL {
            candidateURLs.append(resourcesURL.appendingPathComponent("Workjet_WorkjetApp.bundle", isDirectory: true))
        }
        candidateURLs.append(
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("Workjet_WorkjetApp.bundle", isDirectory: true)
        )
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        candidateURLs.append(
            executableURL
                .deletingLastPathComponent()
                .appendingPathComponent("Workjet_WorkjetApp.bundle", isDirectory: true)
        )
        for url in candidateURLs {
            if let bundle = Bundle(url: url) { bundles.append(bundle) }
        }
        bundles.append(Bundle.main)

        var seen = Set<String>()
        return bundles.filter { seen.insert($0.bundleURL.standardizedFileURL.path).inserted }
    }
}

private extension ModelProvider {
    var resourceName: String {
        switch self {
        case .kimi: return "kimi"
        case .openAI: return "openai"
        case .anthropic: return "anthropic"
        case .antigravity: return "antigravity"
        case .xAI: return "xai"
        case .miniMax: return "minimax"
        case .zAI: return "zai"
        }
    }

    var fallbackMark: String {
        switch self {
        case .openAI: return "O"
        case .anthropic, .antigravity: return "A"
        case .xAI: return "X"
        case .miniMax: return "M"
        case .zAI: return "Z"
        case .kimi: return "K"
        }
    }
}
