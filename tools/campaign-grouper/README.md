# Campaign grouper (prototype)

Rule-based grouping of actual-play podcast episodes into campaigns and arcs, plus linking of
aftershows (e.g. NADDPod's "Short Rest") to the episode they follow. It uses only RSS data
(titles, `itunes:season`, `itunes:episodeType`, publish dates), with no transcripts and no model.

Not part of the app build: `project.yml` only compiles `Muninn/`. `Core/` has no app dependencies,
so it can be moved into `Muninn/Services` when we adopt it.

## Layout

| Path | What |
|---|---|
| `Core/CampaignGrouper.swift` | Episodes → campaigns (from title patterns, then season tags, then Extras/Unsorted), with arcs from trailing "(Arc Name)" |
| `Core/EpisodeLinker.swift` | Finds aftershow labels in a feed and attaches each aftershow to its episode |
| `Harness/FeedLoader.swift` | Minimal RSS loader for the command-line tools |
| `report/` | Prints groups per feed, listing Unsorted titles |
| `campaign/` | Prints campaigns with attached aftershows and arcs for one feed |
| `link/` | Prints aftershow-linking stats and sample links for one feed |
| `experiments/` | On-device Foundation Models trials (token measurement, model labeling). Kept for reference; the model did worse than the rules. |

## Usage

```bash
./fetch-feeds.sh            # public feeds from feeds.tsv → feeds/
./build.sh                  # add --experiments to build the model tools
build/report feeds
build/report feeds critical-role glass-cannon
build/campaign feeds/naddpod.xml "Not Another D&D Podcast"
build/link path/to/premium-feed.xml "Not Another D&D Podcast"
```

Pass the real show name as the second argument for premium feeds. Their channel titles
(e.g. "… Patreon Exclusives") don't match the names used in episode titles.

Keep private/premium feeds in `feeds-private/` (gitignored). Their URLs carry an access token.

## Results (Nov 2026 snapshot)

- 16 public actual-play feeds: 13 of 16 get named campaigns from titles. The rest fall back to
  "Season N", which is correct for those shows. Unsorted is small (Glass Cannon: 64 of 1,133).
- NADDPod Patreon feed (929 episodes, no season/type tags): 303 of 309 "Short Rest" aftershows
  linked, none to the wrong episode; arcs found inside the main run and Campaign 3.
- On-device model (4K context): whole feeds need 6K–42K tokens, so they don't fit. A small
  labeling call misplaced leftovers and once overflowed the window.
