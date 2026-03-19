# VideoMaster — AI Enhancement Suggestions

## High-Value AI Use Cases

### 1. Semantic Search

Current search is filename-based (FTS5). AI could enable natural-language queries such as:
- "short workout videos"
- "family vacation from last year"
- "4K nature documentaries"

Implementation: Embeddings (local model or API) on filenames, tags, and optional notes; combine with metadata filters.

### 2. Auto-Tagging

AI could suggest tags from:
- **Filename/path**: `vacation_2024_beach.mp4` → "vacation", "2024", "beach"
- **Metadata**: duration, resolution, codec → "short", "4K", "HEVC"
- **Content** (vision): scene type, people, setting → "outdoor", "interview", "tutorial"

Batch tagging on import would reduce manual organization.

### 3. Natural-Language Collections

Instead of only rule builders, users could say:
- "Videos under 5 minutes with 4+ stars"
- "Unwatched tutorials"
- "Large 4K files from last month"

AI would translate to `CollectionRule` attributes and values.

### 4. Video Notes / Descriptions

IMPROVEMENTS.md mentions a notes field. AI could:
- Suggest notes from filenames and metadata
- Summarize content from thumbnails or keyframes
- Make notes searchable and usable in collections

### 5. Duplicate Detection

Beyond size/duration/hash, AI could help with:
- Perceptual similarity (same content, different encode)
- Near-duplicates (trimmed, re-encoded)
- Fuzzy filename matching

### 6. Smarter "Surprise Me"

Use tags, ratings, play count, and recency to suggest videos instead of pure random selection.

---

## Implementation Options

| Approach | Pros | Cons |
|---------|------|------|
| **Local models** (Core ML, llama.cpp) | Privacy, offline, no API cost | Setup, size, compute |
| **Cloud API** (OpenAI, etc.) | Strong quality, fast to add | Cost, privacy, latency |
| **Hybrid** | Local for search/tagging, cloud for heavy tasks | More moving parts |

---

## Suggested Starting Point

**Auto-tagging from filenames** is a good first step: no video analysis, works offline with a small local model, and directly improves organization and search.
