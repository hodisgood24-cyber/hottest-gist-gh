#!/usr/bin/env python3
"""Make one small share page per post in posts.js (s/<id>.html) so links
show that story's title and picture in WhatsApp, Facebook, X and Telegram.
Run from the repo root: python3 tools/build_share.py"""
import json, os, re, subprocess, html, glob
SITE = "https://hottest-gist-gh.hodisgood24.workers.dev"
js = "var window={};" + open("posts.js", encoding="utf-8").read() + ";console.log(JSON.stringify(window.POSTS||[]))"
posts = json.loads(subprocess.run(["node", "-e", js], capture_output=True, text=True, check=True).stdout)
os.makedirs("s", exist_ok=True)
keep = set()
for p in posts:
    if not p.get("id") or not p.get("title") or p.get("status") == "draft":
        continue
    pid = p["id"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", pid):
        continue
    imgs = p.get("images") or []
    img = imgs[0] if imgs else "images/og-logo.png"
    img = img if img.startswith("http") else SITE + "/" + img.lstrip("/")
    body = (p.get("body") or "").split("\nSource:")[0].replace("\n", " ").strip()
    desc = (body[:157] + "...") if len(body) > 160 else body or "Fresh Ghana music, entertainment and news."
    e = html.escape
    url = f"{SITE}/s/{pid}.html"
    page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{e(p["title"])} | Hottest Gist GH</title>
<meta name="description" content="{e(desc, True)}">
<link rel="canonical" href="{url}">
<meta property="og:type" content="article"><meta property="og:site_name" content="Hottest Gist GH">
<meta property="og:title" content="{e(p["title"], True)}"><meta property="og:description" content="{e(desc, True)}">
<meta property="og:url" content="{url}"><meta property="og:image" content="{e(img, True)}">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="{e(p["title"], True)}"><meta name="twitter:image" content="{e(img, True)}">
<link rel="icon" href="/favicon.svg">
<style>body{{margin:0;font:17px/1.6 system-ui,sans-serif;background:#fff;color:#16161a}}.w{{max-width:680px;margin:0 auto;padding:20px 16px}}img{{max-width:100%;border-radius:12px}}a.b{{display:inline-block;background:#c8102e;color:#fff;font-weight:800;padding:12px 20px;border-radius:999px;text-decoration:none}}@media(prefers-color-scheme:dark){{body{{background:#111;color:#f2f2f2}}}}</style>
<script>location.replace("/#{pid}");</script></head>
<body><div class="w"><p><b>Hottest Gist GH</b></p><h1>{e(p["title"])}</h1><img src="{e(img, True)}" alt="">
<p>{e(desc)}</p><p><a class="b" href="/#{pid}">Open on Hottest Gist GH</a></p></div></body></html>'''
    open(f"s/{pid}.html", "w", encoding="utf-8").write(page)
    keep.add(f"s/{pid}.html")
for f in glob.glob("s/*.html"):
    if f not in keep:
        os.remove(f)
print("built", len(keep), "share pages")
