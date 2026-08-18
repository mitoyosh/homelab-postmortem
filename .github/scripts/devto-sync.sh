#!/usr/bin/env bash
# Publish one newly-added _posts/*.md file to dev.to via the API, published
# immediately (no draft step), with canonical_url pointing back at the
# original post so search engines credit homelabpostmortem.com as the source.
#
# Usage: devto-sync.sh _posts/YYYY-MM-DD-slug.md
# Requires: DEV_TO_API_KEY env var, curl, jq

set -euo pipefail

FILE="$1"
SITE_URL="${SITE_URL:-https://homelabpostmortem.com}"

if [ -z "${DEV_TO_API_KEY:-}" ]; then
  echo "DEV_TO_API_KEY is not set; skipping $FILE" >&2
  exit 1
fi

if [ ! -f "$FILE" ]; then
  echo "File not found: $FILE" >&2
  exit 1
fi

BASENAME=$(basename "$FILE" .md)
# _posts filenames are YYYY-MM-DD-slug.md; Jekyll's permalink
# (/:year/:month/:day/:title/) derives the URL from exactly this.
DATE_PART=$(echo "$BASENAME" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
SLUG=$(echo "$BASENAME" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')
YEAR=$(echo "$DATE_PART" | cut -d- -f1)
MONTH=$(echo "$DATE_PART" | cut -d- -f2)
DAY=$(echo "$DATE_PART" | cut -d- -f3)
CANONICAL_URL="${SITE_URL}/${YEAR}/${MONTH}/${DAY}/${SLUG}/"

# Front matter is between the first two '---' lines; body is everything after.
FRONT_MATTER=$(awk 'BEGIN{c=0} /^---[[:space:]]*$/{c++; next} c==1{print}' "$FILE")
BODY=$(awk 'BEGIN{c=0} /^---[[:space:]]*$/{c++; next} c>=2{print}' "$FILE")

TITLE=$(echo "$FRONT_MATTER" | grep '^title:' | sed -E 's/^title:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
if [ -z "$TITLE" ]; then
  echo "Could not extract a title from $FILE front matter; skipping" >&2
  exit 1
fi

# Raw Jekyll Liquid tags ({{ ... }}) only get resolved by Jekyll's own build.
# Sent verbatim to dev.to they render as broken/literal text (this bit us once
# already — see the toolkit links in the 2026-08-16/17 posts). Fail loudly
# instead of silently shipping a broken link.
if echo "$BODY" | grep -q '{{'; then
  echo "ERROR: $FILE body still contains raw Liquid syntax ({{ ... }})." >&2
  echo "Use plain absolute URLs (https://homelabpostmortem.com/...) in post bodies instead — this content gets syndicated verbatim." >&2
  exit 1
fi

# Every post gets the same toolkit CTA the site's own post layout adds
# automatically — but that layout isn't visible to this script, since it
# only reads the raw post body, so it has to be appended here too.
CTA=$'\n\n## Toolkit\n\nThis post\'s fix is available as a tested, ready-to-run script in the toolkit.\n\n**[See the toolkit →](https://homelabpostmortem.com/toolkit/)**\n'
BODY="${BODY}${CTA}"

TAGS_RAW=$(echo "$FRONT_MATTER" | grep '^devto_tags:' | sed -E 's/^devto_tags:[[:space:]]*//' || true)
if [ -n "$TAGS_RAW" ]; then
  TAGS_JSON=$(echo "$TAGS_RAW" | jq -R -c 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0)) | .[0:4]')
else
  TAGS_JSON="[]"
fi

PAYLOAD=$(jq -n \
  --arg title "$TITLE" \
  --arg body "$BODY" \
  --arg canonical "$CANONICAL_URL" \
  --argjson tags "$TAGS_JSON" \
  '{article: {title: $title, published: true, body_markdown: $body, tags: $tags, canonical_url: $canonical}}')

echo "Publishing '$TITLE' -> $CANONICAL_URL (tags: $TAGS_JSON)"

RESPONSE=$(curl -sS -w '\n%{http_code}' -X POST https://dev.to/api/articles \
  -H "api-key: $DEV_TO_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY_RESPONSE=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  URL=$(echo "$BODY_RESPONSE" | jq -r '.url // "unknown"')
  echo "Published: $URL"
else
  echo "dev.to API returned HTTP $HTTP_CODE:" >&2
  echo "$BODY_RESPONSE" >&2
  exit 1
fi
