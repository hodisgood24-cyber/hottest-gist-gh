#!/usr/bin/env python3
"""Build one full article page per post in posts.js (s/<id>.html), a story index
(stories.html) and sitemap.xml, so Google can read every story and shared links
show the title and picture in WhatsApp, Facebook, X and Telegram.
Run from the repo root: python3 tools/build_share.py
Change SITE once you have your own domain."""
import json, os, re, subprocess, html, glob, datetime
from urllib.parse import urlparse

SITE = "https://hottest-gist-gh.hodisgood24.workers.dev"
NAME = "Hottest Gist GH"
_m = re.search(r'analytics:\s*"([^"]*)"', open("config.js", encoding="utf-8").read())
ANALYTICS = _m.group(1) if _m else ""
BEACON = (f'<script defer src="https://static.cloudflareinsights.com/beacon.min.js" data-cf-beacon=\'{{"token":"{ANALYTICS}"}}\'></script>'
          if re.fullmatch(r"[A-Za-z0-9]{20,64}", ANALYTICS or "") else "")

js = "var window={};" + open("posts.js", encoding="utf-8").read() + ";console.log(JSON.stringify(window.POSTS||[]))"
posts = json.loads(subprocess.run(["node", "-e", js], capture_output=True, text=True, check=True).stdout)
posts = [p for p in posts if p.get("id") and p.get("title") and p.get("status", "live") != "draft"
         and re.fullmatch(r"[A-Za-z0-9_-]+", p["id"])]
posts.sort(key=lambda p: p.get("ts") or 0, reverse=True)
e = html.escape


def abs_url(u):
    return u if u.startswith("http") else SITE + "/" + u.lstrip("/")


def iso(ts):
    return datetime.datetime.fromtimestamp((ts or 0) / 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def nice_date(ts):
    d = datetime.datetime.fromtimestamp((ts or 0) / 1000, datetime.timezone.utc)
    return f"{d.day} {d.strftime('%B %Y')}"


def link_label(u):
    h = (urlparse(u).hostname or "").removeprefix("www.")
    for k, v in (("tiktok.com", "Watch on TikTok"), ("youtube.com", "Watch on YouTube"), ("youtu.be", "Watch on YouTube"),
                 ("spotify.com", "Listen on Spotify"), ("audiomack.com", "Listen on Audiomack"),
                 ("instagram.com", "View on Instagram"), ("facebook.com", "Watch on Facebook")):
        if h == k or h.endswith("." + k):
            return v
    return "Read the source"


CSS = """:root{--bg:#fbfaf7;--card:#fff;--text:#16161a;--muted:#5f5f68;--line:#e6e2da;--red:#c8102e;--gold:#fcd116;--green:#006b3f}
@media(prefers-color-scheme:dark){:root{--bg:#0f0f0d;--card:#1a1a17;--text:#f4f1ea;--muted:#b4b0a6;--line:#2c2b27}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:18px/1.65 "Public Sans",system-ui,sans-serif}
.flag{height:6px;background:linear-gradient(90deg,#ce1126 33.3%,#fcd116 33.3% 66.6%,#006b3f 66.6%)}
.w{max-width:720px;margin:0 auto;padding:18px max(16px,env(safe-area-inset-left)) 40px}
.top{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:18px}
.brand{display:flex;align-items:center;gap:8px;text-decoration:none;color:var(--text);font:400 22px/1 Anton,Impact,sans-serif;text-transform:uppercase;white-space:nowrap}
.brand img{width:34px;height:34px;border-radius:8px}.brand span{background:var(--green);color:#fff;padding:0 6px;border-radius:4px}
.open{font:800 14px/1 system-ui,sans-serif;background:var(--red);color:#fff;text-decoration:none;padding:10px 14px;border-radius:999px;white-space:nowrap}
.cat{color:var(--red);font-weight:800;font-size:13px;letter-spacing:.08em;text-transform:uppercase}
h1{font:400 clamp(32px,7vw,48px)/1.05 Anton,Impact,sans-serif;margin:6px 0 10px;text-wrap:balance}
.meta{color:var(--muted);font-size:14px;margin-bottom:16px}
.pics{display:grid;gap:8px;margin:0 0 18px}.pics img{width:100%;border-radius:14px;display:block}
.pics.two{grid-template-columns:1fr 1fr}
article p{margin:0 0 16px;overflow-wrap:anywhere}
.src{color:var(--muted);font-size:14px}
.cta{display:flex;flex-wrap:wrap;gap:10px;margin:22px 0}
.cta a{font-weight:800;text-decoration:none;border-radius:999px;padding:12px 18px;font-size:15px}
.cta .p{background:var(--red);color:#fff}.cta .s{border:2px solid var(--line);color:var(--text)}
.more{border-top:1px solid var(--line);margin-top:26px;padding-top:12px}
.more h2{font:400 24px/1.1 Anton,Impact,sans-serif;text-transform:uppercase;margin:6px 0 10px}
.more a{display:flex;gap:12px;align-items:center;text-decoration:none;color:var(--text);padding:10px 0;border-bottom:1px solid var(--line)}
.more img{width:86px;height:58px;object-fit:cover;border-radius:10px;flex:none}
.more b{font-size:16px;line-height:1.3}.more small{display:block;color:var(--muted);font-size:13px}
footer{color:var(--muted);font-size:14px;text-align:center;margin-top:28px}footer a{color:inherit}"""

HEAD_FONTS = '<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Anton&family=Public+Sans:wght@400;700;800&display=swap">'


def header():
    return (f'<div class="flag"></div><div class="w"><div class="top"><a class="brand" href="/"><img src="/favicon.svg" alt="">'
            f'Hottest Gist <span>GH</span></a><a class="open" href="/">Open the app</a></div>')


def footer():
    return (f'<footer>{NAME} · Fresh music, movies and culture from Ghana and beyond.<br>'
            f'<a href="/stories.html">All stories</a> · <a href="/about.html">About</a> · <a href="/privacy.html">Privacy</a></footer></div>')


def rel_url(u):
    return u if u.startswith("http") else "/" + u.lstrip("/")


def card(p):
    imgs = p.get("images") or []
    im = f'<img src="{e(rel_url(imgs[0]), True)}" alt="" loading="lazy">' if imgs else ""
    return (f'<a href="/s/{p["id"]}.html">{im}<span><b>{e(p["title"])}</b>'
            f'<small>{e(p.get("cat") or "News")} · {nice_date(p.get("ts"))}</small></span></a>')


os.makedirs("s", exist_ok=True)
keep = set()
for i, p in enumerate(posts):
    pid = p["id"]
    imgs = [abs_url(x) for x in (p.get("images") or [])]
    og = imgs[0] if imgs else SITE + "/images/og-logo.png"
    raw = p.get("body") or ""
    main, _, src = raw.partition("\nSource:")
    flat = main.replace("\n", " ").strip()
    desc = (flat[:157] + "...") if len(flat) > 160 else flat or "Fresh Ghana music, entertainment and news."
    url = f"{SITE}/s/{pid}.html"
    paras = "".join(f"<p>{e(x.strip())}</p>" for x in re.split(r"\n\s*\n|\n", main) if x.strip())
    if src.strip():
        paras += f'<p class="src">Source: {e(src.strip())}</p>'
    pics = ""
    if imgs:
        cls = "pics two" if len(imgs) == 2 else "pics"
        pics = f'<div class="{cls}">' + "".join(f'<img src="{e(rel_url(u), True)}" alt="{e(p["title"], True)}">' for u in (p.get("images") or [])[:4]) + "</div>"
    btns = f'<a class="p" href="/#{pid}">❤️ Like &amp; comment</a>'
    if p.get("link"):
        btns += f'<a class="s" href="{e(p["link"], True)}" rel="noopener" target="_blank">{e(link_label(p["link"]))}</a>'
    btns += f'<a class="s" href="https://wa.me/?text={e(p["title"], True)}%20{e(url, True)}">Share on WhatsApp</a>'
    related = [q for q in posts if q["id"] != pid and q.get("cat") == p.get("cat")][:3]
    related += [q for q in posts if q["id"] != pid and q not in related][: 5 - len(related)]
    more = '<div class="more"><h2>More gist</h2>' + "".join(card(q) for q in related) + "</div>"
    ld = {"@context": "https://schema.org", "@type": "NewsArticle", "headline": p["title"][:110],
          "image": imgs or [og], "datePublished": iso(p.get("ts")), "dateModified": iso(p.get("ts")),
          "author": {"@type": "Organization", "name": p.get("by") or NAME},
          "publisher": {"@type": "Organization", "name": NAME, "logo": {"@type": "ImageObject", "url": SITE + "/icon-512.png"}},
          "mainEntityOfPage": url, "articleSection": p.get("cat") or "News", "description": desc}
    page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>{e(p["title"])} | {NAME}</title>
<meta name="description" content="{e(desc, True)}">
<link rel="canonical" href="{url}">
<meta property="og:type" content="article"><meta property="og:site_name" content="{NAME}">
<meta property="og:title" content="{e(p["title"], True)}"><meta property="og:description" content="{e(desc, True)}">
<meta property="og:url" content="{url}"><meta property="og:image" content="{e(og, True)}">
<meta property="article:published_time" content="{iso(p.get("ts"))}">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="{e(p["title"], True)}"><meta name="twitter:image" content="{e(og, True)}">
<meta name="theme-color" content="#c8102e"><link rel="icon" href="/favicon.svg"><link rel="manifest" href="/site.webmanifest">
{HEAD_FONTS}
<style>{CSS}</style>{BEACON}
<script type="application/ld+json">{json.dumps(ld, ensure_ascii=False).replace("</", "<\\/")}</script>
</head>
<body>{header()}
<article><div class="cat">{e(p.get("cat") or "News")}</div><h1>{e(p["title"])}</h1>
<div class="meta">By {e(p.get("by") or NAME)} · {nice_date(p.get("ts"))}</div>
{pics}{paras}</article>
<div class="cta">{btns}</div>
{more}
{footer()}</body></html>'''
    open(f"s/{pid}.html", "w", encoding="utf-8").write(page)
    keep.add(f"s/{pid}.html")

for f in glob.glob("s/*.html"):
    if f not in keep:
        os.remove(f)

# Story index page
idx = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>All stories | {NAME}</title>
<meta name="description" content="Every story on {NAME}: Ghana music, Afrobeats, movies, football and trending news.">
<link rel="canonical" href="{SITE}/stories.html"><link rel="icon" href="/favicon.svg">
<meta property="og:title" content="All stories | {NAME}"><meta property="og:image" content="{SITE}/images/og-logo.png">
{HEAD_FONTS}
<style>{CSS}</style>{BEACON}</head>
<body>{header()}<h1>All stories</h1><div class="more" style="border:0;margin:0;padding:0">{"".join(card(p) for p in posts)}</div>{footer()}</body></html>'''
open("stories.html", "w", encoding="utf-8").write(idx)

# Sitemap
urls = [(f"{SITE}/", None, "hourly", "1.0"), (f"{SITE}/stories.html", None, "hourly", "0.9")]
urls += [(f"{SITE}/s/{p['id']}.html", iso(p.get("ts")), None, "0.8") for p in posts]
urls += [(f"{SITE}/{x}", None, None, "0.3") for x in ("about.html", "privacy.html", "terms.html")]
sm = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
for loc, lm, cf, pr in urls:
    sm.append("  <url><loc>" + e(loc) + "</loc>" + (f"<lastmod>{lm}</lastmod>" if lm else "") +
              (f"<changefreq>{cf}</changefreq>" if cf else "") + f"<priority>{pr}</priority></url>")
sm.append("</urlset>")
open("sitemap.xml", "w", encoding="utf-8").write("\n".join(sm) + "\n")
print("built", len(keep), "article pages, stories.html and sitemap.xml")
