#!/usr/bin/env python3
"""Check an isolated OpenList container's API and served Chinese frontend."""
import json
import re
import sys
import time
import urllib.error
import urllib.request


def check(origin):
    if not re.fullmatch(r"http://127\.0\.0\.1:[0-9]+", origin):
        raise ValueError("Expected the isolated container's loopback address")

    def get(path):
        with urllib.request.urlopen(origin + path, timeout=5) as response:
            return response.read(32 * 1024 * 1024).decode("utf-8")

    for attempt in range(60):
        try:
            index = get("/")
            break
        except (urllib.error.URLError, TimeoutError):
            if attempt == 59:
                raise
            time.sleep(1)
    settings = json.loads(get("/api/public/settings"))
    if settings.get("code") != 200:
        raise ValueError("Public settings API did not return success")
    # The locale dictionary is lazy-loaded by the store, not the index entry.
    store = re.search(r'/assets/store-[A-Za-z0-9_-]+\.js', index)
    if not store:
        raise ValueError("Served index is missing the frontend store")
    source = get(store[0])
    entry = re.search(r'\.\./lang/zh-CN/entry\.ts.{0,160}?\./(entry-[A-Za-z0-9_-]+\.js)', source)
    if not entry:
        raise ValueError("Frontend store is missing its Chinese locale import")
    script = get("/assets/" + entry[1])
    decoded = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m[1], 16)), script)
    for phrase in ("下载和复制链接", "短链接"):
        if phrase not in decoded:
            raise ValueError("Served frontend is missing the Chinese label: " + phrase)
    print("PASS container startup, public settings API, Chinese download/copy and short-link assets")


if __name__ == "__main__":
    check(sys.argv[1])
