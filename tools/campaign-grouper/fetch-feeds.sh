#!/bin/zsh
# Downloads the public actual-play feeds listed in feeds.tsv into ./feeds (gitignored).
set -e
cd "${0:A:h}"
mkdir -p feeds
while IFS=$'\t' read -r name url; do
  curl -sL --max-time 60 -A "podcast-feed-audit/1.0" -o "feeds/$name.xml" "$url" &
done < feeds.tsv
wait
ls -la feeds
