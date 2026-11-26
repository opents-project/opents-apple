#!/usr/bin/env bash
set -euo pipefail

app="$1"
archive="$2"
tag="$3"
output="$4"
repo=https://github.com/opents-project/opents-apple
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
: "${SPARKLE_PRIVATE_KEY:?Configure the SPARKLE_PRIVATE_KEY repository Actions secret}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/updates"
cp "$archive" "$work/updates/"
feed="$work/updates/appcast.xml"
status=$(curl -sSL --retry 3 --max-time 60 -w '%{http_code}' -o "$feed" \
  "$repo/releases/download/appcast/appcast.xml")
case "$status" in
  200) mv "$feed" "$work/previous.xml" ;;
  404) rm "$feed" ;;
  *) echo "Could not read the published appcast (HTTP $status)." >&2; exit 1 ;;
esac

tools_url=https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip
tools_sha256=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959
curl -fsSL --retry 3 --max-time 180 -o "$work/sparkle.zip" "$tools_url"
printf '%s  %s\n' "$tools_sha256" "$work/sparkle.zip" | shasum -a 256 -c -
unzip -q "$work/sparkle.zip" bin/generate_appcast -d "$work"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$work/bin/generate_appcast" \
  --ed-key-file - --maximum-deltas 0 --download-url-prefix "$repo/releases/download/$tag/" \
  --link "$repo/releases/tag/$tag" "$work/updates"

signature=$(python3 - "$app/Contents/Info.plist" "$archive" "$feed" "$work/previous.xml" "$repo" "$tag" <<'PY'
import plistlib
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

plist, archive, feed, previous = map(Path, sys.argv[1:5])
repo, tag = sys.argv[5:]
info = plistlib.loads(plist.read_bytes())
ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
document = ET.parse(feed)
channel = document.getroot().find("channel")
item, = channel.findall("item")
build = int(info["CFBundleVersion"])
enclosure = item.find("enclosure")
if (item.findtext("s:version", namespaces=ns) != str(build)
        or item.findtext("s:shortVersionString", namespaces=ns) != tag[1:]
        or enclosure.attrib["url"] != f"{repo}/releases/download/{tag}/{archive.name}"
        or int(enclosure.attrib["length"]) != archive.stat().st_size):
    sys.exit("The generated appcast does not match the release archive.")

if previous.exists():
    old_items = ET.parse(previous).getroot().find("channel").findall("item")
    for old in old_items:
        if int(old.findtext("s:version", namespaces=ns)) >= build:
            sys.exit("A release with this build number or a newer one is already published.")
    channel.extend(old_items[:9])
    ET.register_namespace("sparkle", ns["s"])
    ET.indent(document)
    document.write(feed, encoding="utf-8", xml_declaration=True)

print(enclosure.attrib[f'{{{ns["s"]}}}edSignature'])
PY
)

public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")
swift "$(dirname "$0")/verify-sparkle-signature.swift" "$archive" "$public_key" "$signature"
cp "$feed" "$output"
