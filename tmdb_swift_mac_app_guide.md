# TMDB Movie Lookup macOS App (Swift + SwiftUI) — Build Guide

This guide walks you through building a **macOS SwiftUI app** that:

- Searches movies by name
- Lists results with **title**, **year**, and **TMDB movie id**
- Fetches and displays **poster (cover art)**

It uses **The Movie Database (TMDB) API v3** endpoints and standard Apple networking (`URLSession`).

> Note: In your Plex ripping workflow, FileBot queries TMDB to match movies (helpful context for why TMDB IDs matter).  

---

## 0) Prerequisites

- macOS 13+ (recommended)
- Xcode 15+ (Swift 5.9+ recommended)
- A TMDB API key (or v4 read access token)

---

## 1) Get a TMDB API Key (v3) or Read Access Token (v4)

1. Create a TMDB account:  
   https://www.themoviedb.org/
2. Go to your account **Settings → API** and request API access.
3. You’ll receive either:
   - **API Key (v3)** — simplest for this project  
   - **API Read Access Token (v4)** — can also be used as a Bearer token

For this guide, we’ll use the **v3 API key** as a query parameter.

---

## 2) TMDB Endpoints You’ll Use

### 2.1 Movie Search

`GET https://api.themoviedb.org/3/search/movie?api_key=...&query=...`

Key fields returned per movie:
- `id` (TMDB movie id)
- `title`
- `release_date` (we’ll parse year from this)
- `poster_path` (used to build a poster image URL)

### 2.2 Image URL Basics (Poster)

TMDB returns only a **file path** like:

`/8uO0gUM8aNqYLs1OsTBQiXu0fEv.jpg`

To build a poster URL, you need:

- base: `https://image.tmdb.org/t/p/`
- size: e.g. `w185`, `w342`, `w500`, `original`
- file path: the `poster_path`

Example:
`https://image.tmdb.org/t/p/w342/8uO0gUM8aNqYLs1OsTBQiXu0fEv.jpg`

> Optional: you can call the `/3/configuration` endpoint to fetch the base URL and supported sizes dynamically.  
> For most apps, hardcoding `https://image.tmdb.org/t/p/` and a few sizes is fine.

---

## 3) Project Setup (Xcode)

1. **File → New → Project**
2. Choose **App**
3. Platform: **macOS**
4. Interface: **SwiftUI**
5. Language: **Swift**
6. Bundle Identifier: e.g. `com.yourname.TMDBLookup`

---

## 4) Securely Storing Your API Key

Avoid committing your API key to Git.

### Option A (Simple for local dev): Add it to an `.xcconfig`

1. Create a file `Secrets.xcconfig` (do not commit it)
2. Add:

```
TMDB_API_KEY = your_api_key_here
```

3. In project settings, set your build configuration to use `Secrets.xcconfig`
4. Read it in Swift using `Bundle.main.infoDictionary` by mapping to an Info.plist key, or use a build setting to populate a plist entry.

### Option B (Recommended for shipping): Store in Keychain

For a personal tool, Option A is usually sufficient.

---

## 5) Data Models (Codable)

Create `TMDBModels.swift`:

```swift
import Foundation

struct TMDBSearchResponse: Codable {
    let page: Int?
    let results: [TMDBMovie]
    let totalPages: Int?
    let totalResults: Int?

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
        case totalResults = "total_results"
    }
}

struct TMDBMovie: Codable, Identifiable {
    let id: Int
    let title: String
    let releaseDate: String?
    let posterPath: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case releaseDate = "release_date"
        case posterPath = "poster_path"
    }

    var yearText: String {
        guard let releaseDate, releaseDate.count >= 4 else { return "—" }
        return String(releaseDate.prefix(4))
    }
}
```

---

## 6) Networking Layer

Create `TMDBClient.swift`:

```swift
import Foundation

enum TMDBError: Error, LocalizedError {
    case invalidURL
    case badResponse(Int)
    case decodingFailed
    case emptyQuery

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .badResponse(let code): return "Server returned status code \(code)."
        case .decodingFailed: return "Failed to decode response."
        case .emptyQuery: return "Enter a search term."
        }
    }
}

final class TMDBClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func searchMovies(query: String) async throws -> [TMDBMovie] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TMDBError.emptyQuery }

        var comps = URLComponents(string: "https://api.themoviedb.org/3/search/movie")
        comps?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "include_adult", value: "false")
        ]

        guard let url = comps?.url else { throw TMDBError.invalidURL }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw TMDBError.badResponse(-1) }
        guard (200...299).contains(http.statusCode) else { throw TMDBError.badResponse(http.statusCode) }

        do {
            let decoded = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
            return decoded.results
        } catch {
            throw TMDBError.decodingFailed
        }
    }

    /// Build a poster URL from `posterPath` returned by TMDB.
    func posterURL(path: String?, size: String = "w342") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}
```

---

## 7) View Model (State + Async Search)

Create `MovieSearchViewModel.swift`:

```swift
import Foundation

@MainActor
final class MovieSearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [TMDBMovie] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let client: TMDBClient

    init(client: TMDBClient) {
        self.client = client
    }

    func search() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            results = try await client.searchMovies(query: query)
        } catch {
            results = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func posterURL(for movie: TMDBMovie, size: String = "w185") -> URL? {
        client.posterURL(path: movie.posterPath, size: size)
    }
}
```

---

## 8) SwiftUI UI (Search + Results List + Posters)

Create `ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var vm: MovieSearchViewModel

    init(vm: MovieSearchViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Search movies…", text: $vm.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await vm.search() } }

                Button("Search") {
                    Task { await vm.search() }
                }
                .keyboardShortcut(.defaultAction)
            }

            if vm.isLoading {
                ProgressView()
                    .padding(.vertical, 8)
            }

            if let errorMessage = vm.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            List(vm.results) { movie in
                HStack(spacing: 12) {
                    PosterThumb(url: vm.posterURL(for: movie))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(movie.title)
                            .font(.headline)

                        Text("Year: \(movie.yearText) • TMDB id: \(movie.id)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 520)
    }
}

struct PosterThumb: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ProgressView()
                    .frame(width: 44, height: 66)
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 66)
                    .clipped()
                    .cornerRadius(6)
            case .failure:
                Image(systemName: "photo")
                    .frame(width: 44, height: 66)
            @unknown default:
                EmptyView()
            }
        }
    }
}
```

---

## 9) Wire It Up in Your App Entry Point

In `YourAppNameApp.swift`:

```swift
import SwiftUI

@main
struct YourAppNameApp: App {
    var body: some Scene {
        WindowGroup {
            // 1) Load your key (replace with your preferred approach)
            let apiKey = ProcessInfo.processInfo.environment["TMDB_API_KEY"] ?? "REPLACE_ME"

            // 2) Create client + view model
            let client = TMDBClient(apiKey: apiKey)
            let vm = MovieSearchViewModel(client: client)

            // 3) Inject into view
            ContentView(vm: vm)
        }
    }
}
```

### Tip: Development key without committing it
You can set `TMDB_API_KEY` in your Xcode scheme:
- Product → Scheme → Edit Scheme…
- Run → Arguments → Environment Variables → `TMDB_API_KEY`

---

## 10) Common Enhancements (Recommended)

### A) Debounced search (type-to-search)
Use a `Task` with delay and cancel previous search tasks.

### B) Result sorting
Common UI sort:
- Popularity (TMDB returns it)  
- Year descending  
- Exact title match first  

### C) Detail view
When selecting a movie, call:
`GET /3/movie/{movie_id}`  
…and display overview, runtime, genres, etc.

### D) Image caching
`AsyncImage` does basic caching, but for better performance:
- Use `URLCache` tuning
- Or implement a small in-memory cache keyed by URL

### E) Rate limiting / retry
Handle `429 Too Many Requests` by backing off and retrying.

---

## 11) Troubleshooting

- **No results**: make sure your query isn’t empty and you URL-encode it (URLComponents does this for you).
- **401**: invalid API key / missing key.
- **Posters not loading**: `poster_path` can be nil. Confirm you’re building URL as:
  `https://image.tmdb.org/t/p/w342{poster_path}`

---

## 12) Minimal Checklist

- [ ] Acquire TMDB API key
- [ ] Implement `TMDBClient.searchMovies()`
- [ ] Decode JSON into `TMDBMovie`
- [ ] Display title + year + TMDB id in a List
- [ ] Build poster URL from `poster_path`
- [ ] Display posters with `AsyncImage`

---

## References

- TMDB Search: https://developer.themoviedb.org/reference/search-movie  
- TMDB Image basics: https://developer.themoviedb.org/docs/image-basics  
- TMDB Authentication (application): https://developer.themoviedb.org/docs/authentication-application  
