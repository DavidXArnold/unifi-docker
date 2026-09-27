"""Unit tests for .github/scripts/unifi-updater.py.

Run from the repository root: python3 -m unittest discover -s tests
"""

import contextlib
import importlib.util
import io
import os
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / ".github" / "scripts" / "unifi-updater.py"

spec = importlib.util.spec_from_file_location("unifi_updater", SCRIPT)
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


def rss(*items):
    """Build an RSS feed from (title, link, pubDate) tuples; pubDate may be None."""
    parts = []
    for title, link, date in items:
        date_xml = f"<pubDate>{date}</pubDate>" if date else ""
        parts.append(f"<item><title>{title}</title><link>{link}</link>{date_xml}</item>")
    return f"<rss><channel>{''.join(parts)}</channel></rss>".encode()


def ar_member(name: str, data: bytes) -> bytes:
    header = (
        f"{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(data):<10}".encode() + b"`\n"
    )
    return header + data + (b"\n" if len(data) % 2 else b"")


def make_deb(control: str) -> bytes:
    """Build a minimal .deb laid out the way dpkg-deb writes them."""
    tar_buf = io.BytesIO()
    with tarfile.open(fileobj=tar_buf, mode="w:gz") as tar:
        body = control.encode()
        info = tarfile.TarInfo("./control")
        info.size = len(body)
        tar.addfile(info, io.BytesIO(body))
    return (
        b"!<arch>\n"
        + ar_member("debian-binary", b"2.0\n")
        + ar_member("control.tar.gz", tar_buf.getvalue())
        + ar_member("data.tar.xz", b"not needed")
    )


def range_server(blobs):
    """A stand-in for updater.fetch that serves byte ranges from in-memory blobs."""
    def fetch(url, byte_range=""):
        blob = blobs[url]
        if not byte_range:
            return blob
        start, end = (int(x) for x in byte_range.split("-"))
        return blob[start:end + 1]
    return fetch


CONTROL = """Package: unifi
Version: 10.6.106-36011-1
Depends: binutils, coreutils, curl,
 mongodb-server (>= 1:3.6.0) | mongodb-org-server (>= 3.6.0),
 temurin-25-jre | bellsoft-java25 | openjdk-25-jre-headless
"""


class ParseRssTest(unittest.TestCase):
    def test_prefers_newest_stable_over_earlier_prereleases(self):
        feed = rss(
            ("UniFi Network Application 10.7.2 Beta", "https://x/beta", None),
            ("UniFi Network Application 10.7.1 RC", "https://x/rc", None),
            ("UniFi Network Application 10.6.106", "https://x/stable",
             "Wed, 10 Sep 2026 14:00:00 GMT"),
            ("UniFi Network Application 10.6.101", "https://x/older", None),
        )
        rel = updater.parse_rss_latest(feed)
        self.assertEqual(rel["version"], "10.6.106")
        self.assertEqual(rel["link"], "https://x/stable")
        self.assertEqual(rel["date"], "2026-09-10")

    def test_release_candidate_wording_is_not_stable(self):
        feed = rss(
            ("UniFi Network Application 10.7.1 Release Candidate", "https://x/rc", None),
            ("UniFi Network Application 10.6.106", "https://x/stable", None),
        )
        self.assertEqual(updater.parse_rss_latest(feed)["version"], "10.6.106")

    def test_falls_back_to_rc_then_beta(self):
        rc_feed = rss(
            ("UniFi Network Application 10.7.2 Beta", "https://x/beta", None),
            ("UniFi Network Application 10.7.1 RC", "https://x/rc", None),
        )
        self.assertEqual(updater.parse_rss_latest(rc_feed)["version"], "10.7.1")
        beta_feed = rss(("UniFi Network Application 10.7.2 Beta", "https://x/beta", None))
        self.assertEqual(updater.parse_rss_latest(beta_feed)["version"], "10.7.2")

    def test_skips_items_without_a_version(self):
        feed = rss(
            ("Security advisory", "https://x/advisory", None),
            ("UniFi Network Application 10.6.106", "https://x/stable", None),
        )
        self.assertEqual(updater.parse_rss_latest(feed)["version"], "10.6.106")

    def test_bad_date_is_ignored(self):
        feed = rss(("UniFi Network Application 10.6.106", "https://x/s", "not a date"))
        self.assertEqual(updater.parse_rss_latest(feed)["date"], "")

    def test_empty_feed_raises(self):
        with self.assertRaises(RuntimeError):
            updater.parse_rss_latest(rss())


class DebControlTest(unittest.TestCase):
    URL = "https://dl.example/unifi.deb"

    def test_reads_control_with_range_requests_only(self):
        deb = make_deb(CONTROL)
        calls = []
        serve = range_server({self.URL: deb})

        def fetch(url, byte_range=""):
            calls.append(byte_range)
            return serve(url, byte_range)

        with mock.patch.object(updater, "fetch", fetch):
            self.assertEqual(updater.fetch_deb_control(self.URL), CONTROL)
        self.assertTrue(calls and all(calls), "must never download the whole package")

    def test_required_java(self):
        self.assertEqual(updater.required_java(CONTROL), "25")

    def test_required_java_missing_raises(self):
        with self.assertRaises(RuntimeError):
            updater.required_java("Depends: openjdk-25-jre-headless\n")

    def test_not_a_deb_raises(self):
        with mock.patch.object(updater, "fetch", range_server({self.URL: b"<html>404</html>" * 20})):
            with self.assertRaises(RuntimeError):
                updater.fetch_deb_control(self.URL)


class RepoFilesTest(unittest.TestCase):
    """Runs the updaters against copies of the real repository files."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        for name in ("Dockerfile", "README.md", "docker-build.sh"):
            shutil.copy(REPO / name, self.tmp)
        self.cwd = os.getcwd()
        os.chdir(self.tmp)

    def tearDown(self):
        os.chdir(self.cwd)
        shutil.rmtree(self.tmp)

    def read(self, name):
        return Path(self.tmp, name).read_text(encoding="utf-8")

    def test_update_dockerfile(self):
        url = updater.build_pkgurl("10.7.1")
        updater.update_dockerfile(url)
        self.assertIn(f"ARG PKGURL={url}\n", self.read("Dockerfile"))
        self.assertEqual(self.read("Dockerfile").count("ARG PKGURL="), 1)

    def test_update_readme_replaces_only_the_latest_row(self):
        before = self.read("README.md")
        updater.update_readme("10.7.1", "2026-10-01", "https://x/10.7.1")
        after = self.read("README.md")
        self.assertIn(
            "| [`latest` `v10.7.1`](https://github.com/jacobalberty/unifi-docker/blob/master/Dockerfile) "
            "| Current Stable: Version 10.7.1 as of 2026-10-01 "
            "| [Change Log 10.7.1](https://x/10.7.1) |",
            after,
        )
        changed = [a for a, b in zip(before.splitlines(), after.splitlines()) if a != b]
        self.assertEqual(len(changed), 1)
        self.assertIn("stable-6", after)

    def test_update_build_script_changes_the_jre(self):
        updater.update_build_script("27")
        src = self.read("docker-build.sh")
        self.assertIn("temurin-27-jre", src)
        self.assertNotRegex(src, r"temurin-(?!27-)\d+-jre")

    def test_main_updates_all_files(self):
        version = "10.7.1"
        pkg_url = updater.build_pkgurl(version)
        blobs = {
            updater.FEED_URL: rss((f"UniFi Network Application {version}", "https://x/rel",
                                   "Thu, 01 Oct 2026 09:00:00 GMT")),
            pkg_url: make_deb(CONTROL.replace("25", "26")),
        }
        out = io.StringIO()
        with mock.patch.object(updater, "fetch", range_server(blobs)), contextlib.redirect_stdout(out):
            updater.main()
        self.assertEqual(out.getvalue().strip(), version)
        self.assertIn(f"ARG PKGURL={pkg_url}", self.read("Dockerfile"))
        self.assertIn("temurin-26-jre", self.read("docker-build.sh"))
        self.assertIn(f"Version {version} as of 2026-10-01", self.read("README.md"))

    def test_main_without_feed_date_uses_today(self):
        blobs = {
            updater.FEED_URL: rss(("UniFi Network Application 10.7.1", "https://x/rel", None)),
            updater.build_pkgurl("10.7.1"): make_deb(CONTROL),
        }
        with mock.patch.object(updater, "fetch", range_server(blobs)), \
                contextlib.redirect_stdout(io.StringIO()):
            updater.main()
        self.assertRegex(self.read("README.md"), r"Version 10\.7\.1 as of \d{4}-\d{2}-\d{2} ")


if __name__ == "__main__":
    unittest.main()
