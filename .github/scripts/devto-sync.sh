#!/usr/bin/env bash
# Publish one _posts/*.md file to dev.to via the API, published immediately
# (no draft step), with canonical_url pointing back at the original post so
# search engines credit homelabpostmortem.com as the source.
#
# Usage: devto-sync.sh _posts/YYYY-MM-DD-slug.md
# Requires: DEV_TO_API_KEY env var, curl, jq
#
# 2026-09-09: this script used to POST unconditionally, so a post that was
# corrected after syncing left dev.to serving the wrong advice and there was no
# safe way to fix it — re-dispatching would have created a duplicate article.
# It now looks the article up by canonical_url first and PUTs when it exists.
#
# The lookup failing is a hard error on purpose. Falling back to POST when we
# could not determine whether the article already exists is exactly how you get
# the duplicate this change was written to prevent.

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

# dev.to rejects titles over 128 characters with HTTP 422, and it does so at
# publish time -- after the cover has been resolved and the body assembled, so
# the failure reads like a problem with the post rather than with one field.
# A post can therefore carry `devto_title:` to override the site title, which
# is free to be longer and more specific.
DEVTO_TITLE=$(echo "$FRONT_MATTER" | grep '^devto_title:' | sed -E 's/^devto_title:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
if [ -n "$DEVTO_TITLE" ]; then
  TITLE="$DEVTO_TITLE"
fi

# Check it here rather than letting the API say so, and refuse rather than
# truncating: a title cut at 128 bytes mid-clause is worse than a clear failure.
TITLE_LEN=${#TITLE}
if [ "$TITLE_LEN" -gt 128 ]; then
  echo "Title is $TITLE_LEN characters; dev.to allows 128." >&2
  echo "Add a shorter 'devto_title:' to the front matter of $FILE." >&2
  echo "  title: $TITLE" >&2
  exit 1
fi

# Liquid that Jekyll would have rendered must not reach dev.to verbatim — it
# would show as literal text or a broken link (this bit us once already, in the
# 2026-08-16/17 toolkit links).
# Match Liquid specifically — filters, or site./page. variables — rather than
# any '{{', because Go template syntax in shell examples (docker --format
# '{{.Ports}}') is legitimate content that must survive.
if echo "$BODY" | grep -qE '\{\{[^}]*(\||site\.|page\.)'; then
  echo "ERROR: $FILE body still contains raw Liquid syntax." >&2
  echo "Use plain absolute URLs (https://homelabpostmortem.com/...) in post bodies — this content gets syndicated verbatim." >&2
  exit 1
fi

# Jekyll evaluates Liquid inside code fences too, so Go/Helm template braces
# have to be wrapped in {% raw %} or they render as nothing on the site itself.
if echo "$BODY" | grep -qE '\{\{\s*\.' && ! grep -q '{% raw %}' "$FILE"; then
  echo "ERROR: $FILE has template braces ({{ .Something }}) outside a {% raw %} block." >&2
  echo "Jekyll will evaluate them to an empty string and the published command will be broken." >&2
  exit 1
fi

# Every post gets the same toolkit CTA the site's own post layout adds
# automatically — but that layout isn't visible to this script, since it
# only reads the raw post body, so it has to be appended here too.
# {% raw %} is a Jekyll instruction, meaningless on dev.to. Strip the markers
# but keep what they wrapped.
BODY=$(echo "$BODY" | sed -e 's/{% raw %}//g' -e 's/{% endraw %}//g')

CTA=$'\n\n## Toolkit\n\nThis post\'s fix is available as a tested, ready-to-run script in the toolkit.\n\n**[See the toolkit →](https://homelabpostmortem.com/toolkit/)**\n'
BODY="${BODY}${CTA}"

TAGS_RAW=$(echo "$FRONT_MATTER" | grep '^devto_tags:' | sed -E 's/^devto_tags:[[:space:]]*//' || true)
if [ -n "$TAGS_RAW" ]; then
  TAGS_JSON=$(echo "$TAGS_RAW" | jq -R -c 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0)) | .[0:4]')
else
  TAGS_JSON="[]"
fi

# Cover images live in the site repo at assets/covers/<same-basename>.png.
# dev.to weights them heavily in the home feed, so attach one when it exists
# rather than shipping a post that reads as untitled there.
COVER_URL="${SITE_URL}/assets/covers/${BASENAME}.png"
if [ -f "assets/covers/${BASENAME}.png" ]; then
  echo "Cover: $COVER_URL"
else
  echo "No cover at assets/covers/${BASENAME}.png — publishing without one."
  COVER_URL=""
fi

PAYLOAD=$(jq -n \
  --arg title "$TITLE" \
  --arg body "$BODY" \
  --arg canonical "$CANONICAL_URL" \
  --arg cover "$COVER_URL" \
  --argjson tags "$TAGS_JSON" \
  '{article: {title: $title, published: true, body_markdown: $body, tags: $tags, canonical_url: $canonical}}
   | if $cover != "" then .article.main_image = $cover else . end')

# Does this post already exist on dev.to? /articles/me/all lists the
# authenticated user's own articles, drafts included, and carries canonical_url.
# Match on that rather than on the title: the title is what a correction is most
# likely to change, and canonical_url is derived from the filename, which is
# stable for the life of the post.
EXISTING_ID=""
PAGE=1
while : ; do
  LIST_RESPONSE=$(curl -sS -w '\n%{http_code}' -X GET \
    "https://dev.to/api/articles/me/all?per_page=100&page=${PAGE}" \
    -H "api-key: $DEV_TO_API_KEY")
  LIST_CODE=$(echo "$LIST_RESPONSE" | tail -n1)
  LIST_BODY=$(echo "$LIST_RESPONSE" | sed '$d')
  if [ "$LIST_CODE" -lt 200 ] || [ "$LIST_CODE" -ge 300 ]; then
    echo "Could not list existing dev.to articles (HTTP $LIST_CODE). Refusing to" >&2
    echo "POST blind, because that would duplicate the article if it exists." >&2
    echo "$LIST_BODY" >&2
    exit 1
  fi
  COUNT=$(echo "$LIST_BODY" | jq 'length')
  [ "$COUNT" -eq 0 ] && break
  MATCH=$(echo "$LIST_BODY" | jq -r --arg c "$CANONICAL_URL" \
    'map(select(.canonical_url == $c)) | .[0].id // empty')
  if [ -n "$MATCH" ]; then EXISTING_ID="$MATCH"; break; fi
  PAGE=$((PAGE + 1))
  # /articles/me/all has no documented page cap; stop somewhere rather than
  # looping forever if the API starts returning the same page.
  [ "$PAGE" -gt 20 ] && break
done

if [ -n "$EXISTING_ID" ]; then
  echo "Updating dev.to article $EXISTING_ID: '$TITLE' -> $CANONICAL_URL (tags: $TAGS_JSON)"
  RESPONSE=$(curl -sS -w '\n%{http_code}' -X PUT "https://dev.to/api/articles/${EXISTING_ID}" \
    -H "api-key: $DEV_TO_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")
  VERB="Updated"
elif [ "${DEVTO_UPDATE_ONLY:-0}" = "1" ]; then
  # Safety valve for the first run of the lookup path, and for any run where a
  # duplicate would be worse than no sync: refuse to create, only ever update.
  echo "No dev.to article found with canonical_url $CANONICAL_URL, and" >&2
  echo "DEVTO_UPDATE_ONLY=1, so nothing was created. If you expected an" >&2
  echo "existing article, the lookup is wrong — fix that before creating one." >&2
  exit 1
else
  echo "Publishing '$TITLE' -> $CANONICAL_URL (tags: $TAGS_JSON)"
  RESPONSE=$(curl -sS -w '\n%{http_code}' -X POST https://dev.to/api/articles \
    -H "api-key: $DEV_TO_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")
  VERB="Published"
fi

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY_RESPONSE=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  URL=$(echo "$BODY_RESPONSE" | jq -r '.url // "unknown"')
  echo "${VERB}: $URL"
else
  echo "dev.to API returned HTTP $HTTP_CODE:" >&2
  echo "$BODY_RESPONSE" >&2
  exit 1
fi
