#!/usr/bin/env python3
"""Make an original cover picture for a post (no photos copied from anywhere).
Usage: python3 tools/cover.py "Headline" "Category" images/my-post.jpg
"""
import sys, html, random, hashlib
from playwright.sync_api import sync_playwright

PAL = {
  "Afrobeats": ("#ff6a00", "#ee0979"), "Highlife": ("#f7971e", "#c8102e"),
  "Hiplife": ("#7f00ff", "#e100ff"), "Gospel": ("#1d976c", "#2c5364"),
  "Movies": ("#232526", "#c8102e"), "TV": ("#0f2027", "#2c7be5"),
  "Celebrity": ("#ff0844", "#ffb199"), "Events": ("#c8102e", "#fcd116"),
  "Reviews": ("#134e5e", "#71b280"),
}
EMOJI = {"Afrobeats": "🔥", "Highlife": "🎺", "Hiplife": "🎤", "Gospel": "🙏", "Movies": "🎬",
         "TV": "📺", "Celebrity": "⭐", "Events": "🎟️", "Reviews": "🎧"}

def make(title, cat, out):
    a, b = PAL.get(cat, ("#c8102e", "#006b3f"))
    e = EMOJI.get(cat, "🎶")
    seed = int(hashlib.md5(title.encode()).hexdigest()[:6], 16)
    random.seed(seed)
    dots = "".join(
        f'<i style="left:{random.randint(2,96)}%;top:{random.randint(4,90)}%;width:{(s:=random.randint(30,150))}px;height:{s}px"></i>'
        for _ in range(9))
    size = 74 if len(title) < 55 else 60 if len(title) < 85 else 50
    page = f"""<html><body style="margin:0"><div style="width:1200px;height:630px;position:relative;overflow:hidden;
    background:linear-gradient(135deg,{a},{b});font-family:'Anton','Impact','DejaVu Sans',sans-serif;color:#fff">
    <style>i{{position:absolute;border-radius:50%;background:rgba(255,255,255,.12)}}</style>{dots}
    <div style="position:absolute;top:0;left:0;right:0;height:16px;background:linear-gradient(90deg,#c8102e 33.3%,#fcd116 33.3% 66.6%,#006b3f 66.6%)"></div>
    <div style="position:absolute;left:60px;top:60px;background:#fff;color:#111;font:800 28px 'DejaVu Sans',sans-serif;padding:8px 22px;border-radius:40px">{e} {html.escape(cat.upper())}</div>
    <div style="position:absolute;left:60px;right:60px;top:150px;bottom:130px;display:flex;align-items:center;
      font:800 {size}px/1.12 'DejaVu Sans',sans-serif;text-shadow:0 4px 18px rgba(0,0,0,.35)">{html.escape(title)}</div>
    <div style="position:absolute;left:60px;bottom:40px;font:800 38px 'DejaVu Sans',sans-serif;letter-spacing:1px">HOTTEST GIST <span style="background:#006b3f;padding:2px 14px;border-radius:6px">GH</span></div>
    <div style="position:absolute;right:60px;bottom:48px;font:700 26px 'DejaVu Sans',sans-serif;opacity:.9">hottestgistgh.netlify.app</div>
    </div></body></html>"""
    with sync_playwright() as p:
        br = p.chromium.launch()
        pg = br.new_page(viewport={"width": 1200, "height": 630})
        pg.set_content(page)
        pg.screenshot(path=out, type="jpeg", quality=86)
        br.close()

if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    make(*sys.argv[1:])
