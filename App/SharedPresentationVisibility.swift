// SPDX-License-Identifier: Apache-2.0
struct SharedPresentationVisibility {
  static func shouldPresent(
    visible: Bool, miniaturized: Bool, onActiveSpace: Bool, occlusionVisible: Bool,
    fullscreen: Bool, keyWindow: Bool, applicationActive: Bool
  ) -> Bool {
    visible && !miniaturized && onActiveSpace
      && (occlusionVisible || (fullscreen && keyWindow && applicationActive))
  }
}
