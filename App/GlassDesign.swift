// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// Group nearby native glass effects without applying glass to the content itself.
struct VMGlassGroup<Content: View>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let content: Content

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    Group {
      if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
        GlassEffectContainer(spacing: 8) { content }
      } else {
        content
      }
    }
    .transaction { transaction in
      if reduceMotion {
        transaction.animation = nil
        transaction.disablesAnimations = true
      }
    }
  }
}

/// Passive action-layer status, with no hover, tap or morph behavior.
struct VMGlassBadge: View {
  let title: String
  let symbol: String
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  private var label: some View {
    Label(title, systemImage: symbol)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.primary)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .accessibilityLabel(title)
  }

  var body: some View {
    if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
      label.glassEffect(.regular, in: Capsule())
    } else {
      label
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay {
          Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
  }
}

/// Solid semantic content surfaces keep text, selected paths and forms legible.
struct VMContentCard<Content: View>: View {
  @Environment(\.colorSchemeContrast) private var contrast
  private let title: String?
  private let content: Content

  init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let title {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(22)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(
          Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1.5 : 0.5)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct VMGlassControl: ViewModifier {
  let prominent: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
      if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
    } else {
      if prominent {
        content.buttonStyle(.borderedProminent)
      } else {
        content.buttonStyle(.bordered)
      }
    }
  }
}

private struct VMSupportingText: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  func body(content: Content) -> some View {
    content.foregroundStyle(contrast == .increased ? Color.primary : Color.secondary)
  }
}

extension View {
  func vmGlassControl(prominent: Bool = false) -> some View {
    modifier(VMGlassControl(prominent: prominent))
      .buttonBorderShape(.capsule).controlSize(.large)
  }
  func vmSupportingText() -> some View { modifier(VMSupportingText()) }
}
