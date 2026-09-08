#!/usr/bin/env bash
# Record the mori Project release fact for shinzui/baikai from an observed tag.
#
# Called once per release by the `release` automation (automation/release.dhall).
# That config's `refRegexes` already restricts the trigger to the umbrella
# `baikai-<version>` tag, so this script no longer filters: it exists only to do
# the two things a reaction cannot express -- strip the `baikai-` prefix and
# read the tag's own creation time.
set -euo pipefail

tag=${1:?usage: record-release.sh TAG}

# The selector guarantees this shape, so a mismatch is a bug in the selector or
# a hand-run with the wrong argument -- not the ordinary case it used to be.
# Fail loudly rather than recording a version that breaks the convention below.
if [[ ! $tag =~ ^baikai-([0-9]+(\.[0-9]+)*)$ ]]; then
  echo "record-release: $tag is not an umbrella baikai release tag" >&2
  exit 1
fi

# Mori keeps one release fact per project and baikai's project version is the
# umbrella package's, recorded without the tag prefix -- `0.6.0.1`, not
# `baikai-0.6.0.1`. Versions are opaque to mori, so nothing but this line
# enforces that.
version=${BASH_REMATCH[1]}

# The tag's own creation time, not the observation time. The two agree when the
# daemon is healthy, but ingest can lag a tag by months -- baikai's did between
# 2026-06-13 and 2026-08-28 -- and the release fact is immutable, so a wrong
# first write cannot be corrected later. Fall back to mori's default (now) only
# when git has nothing to offer.
released_at=$(TZ=UTC git for-each-ref \
  --format='%(creatordate:format-local:%Y-%m-%dT%H:%M:%SZ)' \
  "refs/tags/${tag}")

if [[ -n $released_at ]]; then
  exec mori registry release record shinzui/baikai "$version" \
    --released-at "$released_at" \
    --source "git-tag:${tag}"
fi

exec mori registry release record shinzui/baikai "$version" \
  --source "git-tag:${tag}"
