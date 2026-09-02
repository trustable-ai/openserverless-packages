#!/bin/bash
# Regenerate the bucket's index.html from the .deb files it currently holds.
# Safe to run on its own; publish.sh runs it after every upload.
set -euo pipefail
cd "$(dirname $0)"

echo "=== INDEX ==="

missing=()
for v in S3_ENDPOINT S3_ZONE S3_KEY S3_SECRET; do
    if [ -z "${!v:-}" ]; then missing+=("$v"); fi
done
if [ "${#missing[@]}" -ne 0 ]; then
    echo "Missing required environment variable(s): ${missing[*]}" >&2
    exit 1
fi

BUCKET="openserverless"
PUBLIC_URL="https://openserverless.nuvolaris.download"

export AWS_ACCESS_KEY_ID="${S3_KEY}"
export AWS_SECRET_ACCESS_KEY="${S3_SECRET}"
export AWS_DEFAULT_REGION="${S3_ZONE}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
LISTING="${WORKDIR}/listing.txt"
HTML="${WORKDIR}/index.html"
JSON="${WORKDIR}/index.json"

# list-objects-v2 reports LastModified as ISO-8601 UTC, unlike `s3 ls` which
# renders timestamps in the runner's local timezone. Output is tab-separated:
# 2026-08-31T12:54:35.216000+00:00<TAB>3037597590<TAB>openserverless_..._amd64.deb
aws --endpoint-url "${S3_ENDPOINT}" s3api list-objects-v2 \
    --bucket "${BUCKET}" \
    --query 'Contents[].[LastModified,Size,Key]' \
    --output text > "${LISTING}"

# Split the ISO stamp into "date time" (dropping fractional seconds and the
# +00:00 offset) so the fields match what the formatter below expects.
awk -F'\t' '$3 ~ /^openserverless_.*\.deb$/ {
    split($1, t, "T")
    sub(/\..*$/, "", t[2])
    print t[1]" "t[2]" "$2" "$3
}' "${LISTING}" > "${LISTING}.deb"

if [ ! -s "${LISTING}.deb" ]; then
    echo "No .deb files found in s3://${BUCKET}/" >&2
    exit 1
fi

echo "Indexing $(wc -l < "${LISTING}.deb" | tr -d ' ') package(s)"

# Group by version, newest version first (by the most recent file in it).
# Fields in: date time size name -> version is the middle _-separated field.
PUBLIC_URL="${PUBLIC_URL}" awk '
function human(b,   u,i,v) {
    split("B KB MB GB TB", u, " ")
    i = 1; v = b
    while (v >= 1024 && i < 5) { v /= 1024; i++ }
    return sprintf("%.1f %s", v, u[i])
}
{
    date = $1; time = $2; size = $3; name = $4
    # openserverless_<version>_<arch>.deb
    body = name
    sub(/^openserverless_/, "", body)
    sub(/\.deb$/, "", body)
    p = index(body, "_")
    version = substr(body, 1, p - 1)
    arch = substr(body, p + 1)

    stamp = date " " time
    key = version
    if (!(key in seen)) { seen[key] = 1; versions[++n] = key }
    # Track the newest timestamp in each version group for ordering.
    if (stamp > latest[key]) latest[key] = stamp

    rows[key] = rows[key] sprintf("        <tr><td><a href=\"%s/%s\">%s</a></td><td>%s</td><td class=\"num\">%s</td><td>%s</td></tr>\n", \
        ENVIRON["PUBLIC_URL"], name, arch, stamp " UTC", human(size), name)
}
END {
    # Sort version groups by their latest timestamp, descending.
    for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
            if (latest[versions[j]] > latest[versions[i]]) {
                t = versions[i]; versions[i] = versions[j]; versions[j] = t
            }

    print "<!doctype html>"
    print "<html lang=\"en\">"
    print "<head>"
    print "<meta charset=\"utf-8\">"
    print "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    print "<title>Apache OpenServerless \xe2\x80\x94 Downloads</title>"
    print "<style>"
    print ":root { color-scheme: light dark; --fg: #1a1a1a; --muted: #666; --bg: #fff; --line: #e2e2e2; --accent: #0b5fff; }"
    print "@media (prefers-color-scheme: dark) { :root { --fg: #e8e8e8; --muted: #9a9a9a; --bg: #16181c; --line: #2e3238; --accent: #6ea8ff; } }"
    print "* { box-sizing: border-box; }"
    print "body { margin: 0; padding: 2.5rem 1.25rem 4rem; background: var(--bg); color: var(--fg);"
    print "  font: 16px/1.55 -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, Helvetica, Arial, sans-serif; }"
    print "main { max-width: 60rem; margin: 0 auto; }"
    print "h1 { font-size: 1.6rem; margin: 0 0 .35rem; letter-spacing: -.01em; }"
    print "p.sub { margin: 0 0 2.5rem; color: var(--muted); }"
    print "section { margin-bottom: 2.5rem; }"
    print "h2 { font-size: 1.05rem; margin: 0 0 .1rem; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }"
    print "h2 .date { font-family: inherit; font-weight: 400; font-size: .85rem; color: var(--muted); margin-left: .6rem; }"
    print ".wrap { overflow-x: auto; }"
    print "table { border-collapse: collapse; width: 100%; margin-top: .75rem; font-size: .92rem; }"
    print "th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid var(--line); white-space: nowrap; }"
    print "th { font-weight: 600; font-size: .78rem; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }"
    print "td.num { text-align: right; font-variant-numeric: tabular-nums; }"
    print "td:last-child { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .84rem; color: var(--muted); }"
    print "a { color: var(--accent); text-decoration: none; font-weight: 600; }"
    print "a:hover { text-decoration: underline; }"
    print "footer { margin-top: 3rem; color: var(--muted); font-size: .85rem; }"
    print "</style>"
    print "</head>"
    print "<body>"
    print "<main>"
    print "<h1>Apache OpenServerless</h1>"
    print "<p class=\"sub\">Debian packages, newest first. Install with <code>sudo apt install ./&lt;file&gt;.deb</code></p>"

    for (i = 1; i <= n; i++) {
        v = versions[i]
        printf "<section>\n<h2>%s<span class=\"date\">%s UTC</span></h2>\n", v, latest[v]
        print "<div class=\"wrap\">"
        print "<table>"
        print "  <thead><tr><th>Architecture</th><th>Published</th><th>Size</th><th>File</th></tr></thead>"
        print "  <tbody>"
        printf "%s", rows[v]
        print "  </tbody>"
        print "</table>"
        print "</div>"
        print "</section>"
    }

    printf "<footer>Generated from the bucket contents. Machine-readable index: <a href=\"%s/index.json\">index.json</a></footer>\n", ENVIRON["PUBLIC_URL"]
    print "</main>"
    print "</body>"
    print "</html>"
}' "${LISTING}.deb" > "${HTML}"

aws --endpoint-url "${S3_ENDPOINT}" \
    s3 cp "${HTML}" "s3://${BUCKET}/index.html" \
    --acl public-read \
    --content-type "text/html; charset=utf-8" \
    --cache-control "public, max-age=300"

# Machine-readable companion: { arch: { version: url, ..., "latest": url } }
# where "latest" is the version with the most recent upload for that arch.
PUBLIC_URL="${PUBLIC_URL}" awk '
{
    date = $1; time = $2; name = $4
    body = name
    sub(/^openserverless_/, "", body)
    sub(/\.deb$/, "", body)
    p = index(body, "_")
    version = substr(body, 1, p - 1)
    arch = substr(body, p + 1)
    stamp = date " " time

    url = ENVIRON["PUBLIC_URL"] "/" name
    if (!((arch SUBSEP version) in urls)) {
        if (!(arch in archseen)) { archseen[arch] = 1; arches[++na] = arch }
        vcount[arch]++
        vers[arch, vcount[arch]] = version
    }
    urls[arch, version] = url
    # Newest upload for this arch decides "latest".
    if (stamp > latest_stamp[arch]) { latest_stamp[arch] = stamp; latest_url[arch] = url }
}
END {
    printf "{\n"
    for (i = 1; i <= na; i++) {
        a = arches[i]
        printf "  \"%s\": {\n", a
        for (j = 1; j <= vcount[a]; j++) {
            v = vers[a, j]
            printf "    \"%s\": \"%s\",\n", v, urls[a, v]
        }
        printf "    \"latest\": \"%s\"\n", latest_url[a]
        printf "  }%s\n", (i < na ? "," : "")
    }
    printf "}\n"
}' "${LISTING}.deb" > "${JSON}"

aws --endpoint-url "${S3_ENDPOINT}" \
    s3 cp "${JSON}" "s3://${BUCKET}/index.json" \
    --acl public-read \
    --content-type "application/json" \
    --cache-control "public, max-age=300"

echo "Index published: ${PUBLIC_URL}/index.html"
echo "Index published: ${PUBLIC_URL}/index.json"
