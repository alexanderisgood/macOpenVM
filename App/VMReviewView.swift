// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The session owns selection/window/generation admission and modal routing.
@MainActor struct VMReviewView: View {
  @ObservedObject var review: VMReviewController
  let context: VMReviewContext
  let operationErrorPending: Bool
  let canRefresh: () -> Bool
  let refresh: () -> Void
  let done: () -> Void

  var body: some View {
    VMGlassGroup {
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            Text("Review VM").font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(context.configuration.name).font(.headline).textSelection(.enabled)
            Text(context.configurationURL.deletingLastPathComponent().path)
              .font(.caption).vmSupportingText().textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
            Text(VMReviewPresentation.scope).font(.callout).vmSupportingText()
              .fixedSize(horizontal: false, vertical: true)
            if operationErrorPending {
              Label(
                "Another VM operation needs attention. Choose Done to review its message.",
                systemImage: "exclamationmark.triangle"
              )
              .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if review.isLoading {
              HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Reviewing files and recorded metadata…")
              }.accessibilityElement(children: .combine)
            }
            if let error = review.error {
              Label(error.rawValue, systemImage: "exclamationmark.triangle")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Review error: \(error.rawValue)")
            }
            if let report = review.presentation, review.context == context {
              VMContentCard("Structural check") {
                Label(report.summary, systemImage: "doc.text.magnifyingglass")
                  .font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(report.writer).font(.callout).vmSupportingText()
                Text(report.intent).font(.callout).vmSupportingText()
              }
              if report.hasUnrecognizedFacts {
                Label(
                  "Some report fields could not be shown. Preserve the VM and use the separate support report for further review.",
                  systemImage: "exclamationmark.triangle"
                )
                .font(.callout).fixedSize(horizontal: false, vertical: true)
              }
              VMContentCard("Findings") {
                if report.findings.isEmpty {
                  Text(
                    "No listed structural findings at this check. Guest health and boot readiness remain unverified."
                  )
                  .font(.callout).vmSupportingText()
                } else {
                  ForEach(report.findings) { finding in
                    VStack(alignment: .leading, spacing: 6) {
                      Text(finding.title).font(.headline).accessibilityAddTraits(.isHeader)
                      Text(finding.guidance).font(.callout).vmSupportingText()
                        .fixedSize(horizontal: false, vertical: true)
                    }
                  }
                }
              }
              VMContentCard("Observed files") {
                ForEach(report.files) { file in
                  LabeledContent(file.title) { Text(file.status) }.font(.callout)
                }
                Text(
                  "A file’s presence does not verify its contents, guest data or runtime compatibility."
                )
                .font(.caption).vmSupportingText()
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading).padding(28)
        }
        Divider()
        HStack(spacing: 12) {
          Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
            .vmGlassControl().disabled(review.isLoading || !canRefresh())
            .accessibilityHint("Repeat this VM’s read-only structural checks")
          Spacer()
          Button("Done", action: done).vmGlassControl(prominent: true)
            .keyboardShortcut(.defaultAction)
        }.padding(.horizontal, 28).padding(.vertical, 18)
      }
    }
    .frame(
      minWidth: 600, idealWidth: 680, maxWidth: 800, minHeight: 460, idealHeight: 650,
      maxHeight: 800
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .onExitCommand(perform: done)
  }
}
