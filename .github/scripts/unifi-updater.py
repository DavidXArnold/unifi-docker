#!/usr/bin/env python3
import urllib.request
import xml.etree.ElementTree as ET
import io
import re
import sys
import tarfile
import email.utils
from datetime import datetime, timezone

FEED_URL = "https://community.ui.com/rss/releases/UniFi-Network-Application/e6712595-81bb-4829-8e42-9e2630fabcfe"
DOCKERFILE = "Dockerfile"
README = "README.md"
BUILD_SCRIPT = "docker-build.sh"


def fetch(url: str, byte_range: str = "") -> bytes:
    headers = {"User-Agent": "Mozilla/5.0 (GitHub Actions UniFi Updater)"}
    if byte_range:
        headers["Range"] = f"bytes={byte_range}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def parse_rss_latest(feed_bytes):
    """
    Parse the RSS feed and pick the newest release.

    Priority:
    1. Stable (no 'beta', 'rc', or 'release candidate' in title)
    2. RC (no 'beta' in title)
    3. Any entry with a version, as a last resort
    """
    root = ET.fromstring(feed_bytes)
    items = root.findall(".//item")
    if not items:
        raise RuntimeError("No <item> entries in RSS feed")

    releases = []

    for item in items:
        title_el = item.find("title")
        link_el = item.find("link")
        date_el = item.find("pubDate")

        if title_el is None or link_el is None:
            continue

        title = (title_el.text or "").strip()
        link = (link_el.text or "").strip()
        date_raw = (date_el.text or "").strip() if date_el is not None else ""

        # Try to extract version like 10.0.160 or 9.5.21
        m = re.search(r"(\d+\.\d+\.\d+)", title)
        if not m:
            # Fallback to 2-part versions like 10.0
            m = re.search(r"(\d+\.\d+)", title)
        if not m:
            continue

        version = m.group(1)

        if date_raw:
            try:
                dt = email.utils.parsedate_to_datetime(date_raw)
                date_str = dt.date().isoformat()
            except Exception:
                date_str = ""
        else:
            date_str = ""

        releases.append(
            {
                "title": title,
                "title_lc": title.lower(),
                "version": version,
                "link": link,
                "date": date_str,
            }
        )

    if not releases:
        raise RuntimeError("No releases with a recognizable version found in RSS feed")

    # 1. Prefer "stable" (no beta/rc)
    stable = [
        r for r in releases
        if not any(tag in r["title_lc"] for tag in ("beta", " rc", "release candidate"))
    ]
    if stable:
        return stable[0]

    # 2. Fallback: allow RCs but still skip explicit "beta"
    rc = [r for r in releases if "beta" not in r["title_lc"]]
    if rc:
        return rc[0]

    # 3. Last resort: whatever is first in the feed
    return releases[0]


def build_pkgurl(version: str) -> str:
    """
    Construct the expected sysvinit .deb URL from the version.
    Example: 9.5.21 -> https://dl.ui.com/unifi/9.5.21/unifi_sysvinit_all.deb
    """
    return f"https://dl.ui.com/unifi/{version}/unifi_sysvinit_all.deb"


def fetch_deb_control(url: str) -> str:
    """
    Read the control file of a remote .deb without downloading the whole package.
    A .deb is an ar archive whose second member is control.tar.*, so only the
    first few hundred KB are needed.
    """
    head = fetch(url, "0-131")
    if not head.startswith(b"!<arch>\n"):
        raise RuntimeError(f"{url} is not a .deb archive")
    # Global header (8) + debian-binary header (60) + its 4-byte body, then the
    # control member header: name(16) mtime(12) uid(6) gid(6) mode(8) size(10) magic(2)
    member = head[72:132]
    name = member[:16].decode().strip()
    size = int(member[48:58].decode().strip())
    if not name.startswith("control.tar"):
        raise RuntimeError(f"Unexpected .deb layout: second member is {name!r}")
    data = fetch(url, f"132-{132 + size - 1}")
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        for m in tar.getmembers():
            if m.name.lstrip("./") == "control":
                return tar.extractfile(m).read().decode()
    raise RuntimeError("control file not found in .deb")


def required_java(control: str) -> str:
    """Return the Java major version the package depends on, e.g. '25'."""
    m = re.search(r"temurin-(\d+)-jre", control)
    if not m:
        raise RuntimeError("Could not find a temurin JRE dependency in the package")
    return m.group(1)


def update_build_script(java: str) -> None:
    with open(BUILD_SCRIPT, "r", encoding="utf-8") as f:
        src = f.read()

    new_src, subs = re.subn(r"temurin-\d+-jre", f"temurin-{java}-jre", src)
    if subs == 0:
        raise RuntimeError(f"Failed to find the temurin JRE in {BUILD_SCRIPT}")

    if new_src != src:
        with open(BUILD_SCRIPT, "w", encoding="utf-8") as f:
            f.write(new_src)


def update_dockerfile(url: str) -> None:
    with open(DOCKERFILE, "r", encoding="utf-8") as f:
        src = f.read()

    new_src, subs = re.subn(
        r"ARG\s+PKGURL=.*",
        f"ARG PKGURL={url}",
        src,
        count=1,
    )

    if subs == 0:
        raise RuntimeError("Failed to update PKGURL in Dockerfile")

    if new_src != src:
        with open(DOCKERFILE, "w", encoding="utf-8") as f:
            f.write(new_src)


def update_readme(version: str, date_str: str, link: str) -> None:
    with open(README, "r", encoding="utf-8") as f:
        src = f.read()

    new_row = (
        f"| [`latest` `v{version}`](https://github.com/jacobalberty/unifi-docker/blob/master/Dockerfile) "
        f"| Current Stable: Version {version} as of {date_str} "
        f"| [Change Log {version}]({link}) |"
    )

    # Replace the first "latest" row in the Current Information table
    new_src, subs = re.subn(
        r"^\| \[`latest` `v[0-9.]+`\]\(.*?\) \| Current Stable: Version [0-9.]+ as of [0-9-]+ \| \[Change Log [0-9.]+\]\(.*?\) \|$",
        new_row,
        src,
        count=1,
        flags=re.MULTILINE,
    )

    if subs == 0:
        raise RuntimeError("Failed to update README row")

    if new_src != src:
        with open(README, "w", encoding="utf-8") as f:
            f.write(new_src)


def main() -> None:
    feed = fetch(FEED_URL)
    rel = parse_rss_latest(feed)

    version = rel["version"]
    link = rel["link"]
    date_str = rel["date"] or datetime.now(timezone.utc).date().isoformat()

    pkg_url = build_pkgurl(version)

    # Keep the JRE in step with what the package requires, otherwise the
    # build fails when UniFi moves to a newer Java.
    update_build_script(required_java(fetch_deb_control(pkg_url)))
    update_dockerfile(pkg_url)
    update_readme(version, date_str, link)

    # Printed so GitHub Actions step can capture it
    print(version)


if __name__ == "__main__":
    main()
