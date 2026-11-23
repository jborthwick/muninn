#!/bin/zsh
# Builds the command-line harnesses into ./build. macOS 26.4+ (the model experiments need Apple Intelligence).
set -e
cd "${0:A:h}"
mkdir -p build
CORE=(Core/CampaignGrouper.swift Core/EpisodeLinker.swift Harness/FeedLoader.swift)
for tool in report campaign link; do
  swiftc -O -o build/$tool $CORE $tool/main.swift
done
if [[ "$1" == "--experiments" ]]; then
  for tool in llm measure; do
    swiftc -O -target arm64-apple-macosx26.4 -o build/$tool $CORE experiments/$tool/main.swift
  done
fi
echo "Built into $(pwd)/build"
