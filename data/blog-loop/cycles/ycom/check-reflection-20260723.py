#!/usr/bin/env python3
"""Cycle 042 (2026-07-23) read-only live check: reflection status of pending fixes.
Targets: p=77/p=5050 (drafts 8362/8363), p=2117/p=8299 (B-013 meta), p=7097/p=388/p=7306 (B-015 titles).
Also fetches /contents/ index to detect new publications.
"""
import re
import html
import time
import urllib.request

UA = {"User-Agent": "Mozilla/5.0 (compatible; blog-loop-check)"}


def fetch(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", "replace"), r.geturl()


for p in [77, 5050, 2117, 8299, 7097, 388, 7306]:
    url = "https://y-com.info/?p=%d" % p
    try:
        d, final = fetch(url)
    except Exception as e:
        print("=== p=%d ERROR: %s" % (p, e))
        continue
    t = re.search(r"<title>(.*?)</title>", d, re.S)
    m = re.search(r'<meta name="description" content="(.*?)"', d, re.S)
    h1 = re.findall(r"<h1[^>]*>", d)
    print("=== p=%d -> %s" % (p, final))
    print("title:", html.unescape(t.group(1).strip()) if t else "N/A")
    print("meta :", html.unescape(m.group(1).strip())[:130] if m else "N/A")
    print("h1count:", len(h1))
    time.sleep(2)

print("\n=== /contents/ index (latest posts) ===")
try:
    d, _ = fetch("https://y-com.info/contents/")
    # list article links + titles
    items = re.findall(r'<a[^>]+href="(https://y-com\.info/\?p=\d+)"[^>]*>(.*?)</a>', d, re.S)
    seen = set()
    count = 0
    for href, txt in items:
        txt = re.sub(r"<[^>]+>", "", txt).strip()
        if href in seen or not txt:
            continue
        seen.add(href)
        print(href, "|", html.unescape(txt)[:60])
        count += 1
        if count >= 15:
            break
except Exception as e:
    print("ERROR:", e)
