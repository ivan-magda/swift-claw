import ClawCore

package enum LearningViewInspection {
  package static func onlyReadable(in views: [JobLearningView]) -> ReadableJobLearningView? {
    guard views.count == 1, case .readable(let view) = views[0] else {
      return nil
    }
    return view
  }

  package static func isOnlyUnreadable(_ views: [JobLearningView]) -> Bool {
    guard views.count == 1, case .unreadable = views[0] else {
      return false
    }
    return true
  }
}
