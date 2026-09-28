import Foundation

// End-to-end check of the real chain on the real disc, with live TMDB:
//   volume label -> DiscLabelSplit -> TMDB lookup -> FeatureMatching.bestSplit
// Uses the shipping types, compiled standalone. No app, no disc access.

let key = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard !key.isEmpty else { fputs("usage: e2e <tmdb-key>\n", stderr); exit(2) }

func get(_ path: String, _ query: [String: String]) -> [String: Any]? {
    var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    items.append(URLQueryItem(name: "api_key", value: key))
    var components = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
    components.queryItems = items
    var result: [String: Any]?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: components.url!) { data, _, _ in
        if let data { result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 30)
    return result
}

/// The caller's TMDB search, as `bestSplit` takes it.
var cache: [String: FeatureMatching.Candidate?] = [:]
func lookUp(_ term: String) -> FeatureMatching.Candidate? {
    if let hit = cache[term] { return hit }
    var found: FeatureMatching.Candidate?
    if let search = get("search/movie", ["query": term]),
       let results = search["results"] as? [[String: Any]],
       let top = results.first,
       let id = top["id"] as? Int,
       let title = top["title"] as? String {
        let year = String((top["release_date"] as? String ?? "").prefix(4))
        if let detail = get("movie/\(id)", [:]), let runtime = detail["runtime"] as? Int, runtime > 0 {
            found = FeatureMatching.Candidate(term: term, movieID: id, title: title,
                                              year: year, runtimeMinutes: runtime)
        }
    }
    cache[term] = found
    return found
}

struct Case {
    let name: String
    let label: String
    /// (title index, duration seconds) straight from the captured scans.
    let features: [(Int, Int)]
    let expected: Set<Int>
}

let cases = [
    Case(name: "Uncle Buck / The Great Outdoors",
         label: "UNCLE_BUCK_GREAT_OUTDOORS",
         features: [(1, 5_425), (2, 5_978)],
         expected: [2616, 2617]),
    Case(name: "Get Hard / The Campaign (catalogue-number label)",
         label: "7000078778_1",
         features: [(4, 5_122), (5, 6_012)],
         expected: []),
]

var failures = 0
for testCase in cases {
    print("=== \(testCase.name)")
    print("    label: \(testCase.label)")
    let titles = testCase.features.map {
        DiscTitle(index: $0.0, durationSeconds: $0.1, chapterCount: 17,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
    }
    let splits = DiscLabelSplit.candidateSplits(volumeName: testCase.label, count: titles.count)
    print("    splits proposed: \(splits.count)")
    for split in splits { print("      \(split)") }

    guard let assignments = FeatureMatching.bestSplit(
        features: titles, splits: splits, lookUp: lookUp) else {
        if testCase.expected.isEmpty {
            print("    -> no assignment, as expected\n")
        } else {
            print("    -> FAILED: expected \(testCase.expected), got nothing\n")
            failures += 1
        }
        continue
    }
    for a in assignments {
        print(String(format: "    title %d  <-  %@ (%@)  tmdb-%d   %.1f min out",
                     a.feature, a.candidate.title, a.candidate.year,
                     a.candidate.movieID, a.errorMinutes))
    }
    let got = Set(assignments.map(\.candidate.movieID))
    if got == testCase.expected {
        print("    -> MATCHES the library ids\n")
    } else {
        print("    -> FAILED: expected \(testCase.expected), got \(got)\n")
        failures += 1
    }
}
exit(failures == 0 ? 0 : 1)
