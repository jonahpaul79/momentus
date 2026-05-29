import SwiftUI

@Observable final class NotesViewModel {
    var searchText: String = ""
    var selectedFilter: RecordingFilter = .all

    func filteredRecordings(from store: RecordingsStore) -> [Recording] {
        let all = store.recordings
        let filtered = filter(all)
        guard !searchText.isEmpty else { return filtered }
        let q = searchText.lowercased()
        return filtered.filter { r in
            r.title.lowercased().contains(q)
            || (r.summary?.executiveSummary.lowercased().contains(q) ?? false)
        }
    }

    private func filter(_ recordings: [Recording]) -> [Recording] {
        switch selectedFilter {
        case .all:
            return recordings
        case .thisWeek:
            let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            return recordings.filter { $0.startedAt >= start }
        case .withActionItems:
            return recordings.filter { $0.hasActionItems }
        case .lowConfidence:
            return recordings.filter { $0.isLowConfidence }
        case .favorites:
            return recordings.filter { $0.isFavorite }
        }
    }
}
