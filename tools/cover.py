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
  "News": ("#0f2027", "#c8102e"), "Trending": ("#8e2de2", "#ff0844"),
  "Sports": ("#11998e", "#38ef7d"), "Business": ("#141e30", "#f7971e"),
  "Tech": ("#0575e6", "#021b79"), "Lifestyle": ("#ee9ca7", "#ffdde1"),
  "Education": ("#1e3c72", "#2a5298"),
}
EMOJI = {"Afrobeats": "🔥", "Highlife": "🎺", "Hiplife": "🎤", "Gospel": "🙏", "Movies": "🎬",
         "TV": "📺", "Celebrity": "⭐", "Events": "🎟️", "Reviews": "🎧",
         "News": "📰", "Trending": "📈", "Sports": "⚽", "Business": "💰", "Tech": "💻", "Lifestyle": "✨", "Education": "🎓"}


ART = {
"school": """<rect x="55" y="160" width="250" height="150" rx="8" fill="#fff"/>
<polygon points="35,165 180,75 325,165" fill="#fcd116"/>
<rect x="154" y="225" width="52" height="85" rx="5" fill="#c8102e"/>
<rect x="80" y="190" width="42" height="42" rx="4" fill="#9ec5ff"/><rect x="238" y="190" width="42" height="42" rx="4" fill="#9ec5ff"/>
<circle cx="180" cy="135" r="17" fill="#fff"/><path d="M180 124v11l8 5" stroke="#333" stroke-width="3" fill="none" stroke-linecap="round"/>
<rect x="178" y="30" width="4" height="48" fill="#fff"/><polygon points="182,32 222,44 182,56" fill="#006b3f"/>
<rect x="30" y="312" width="300" height="12" rx="6" fill="rgba(255,255,255,.55)"/>
<rect x="250" y="262" width="62" height="46" rx="4" fill="#fcd116" transform="rotate(-8 280 285)"/><rect x="256" y="268" width="50" height="34" rx="3" fill="#fff" transform="rotate(-8 280 285)"/>""",
"gold": """<polygon points="40,290 70,230 190,230 220,290" fill="#fcd116"/><polygon points="130,230 160,170 280,170 310,230" fill="#f7b500"/><polygon points="70,230 100,170 190,170 160,230" fill="#ffe27a"/>
<polygon points="95,170 120,115 215,115 190,170" fill="#fcd116"/>
<circle cx="285" cy="285" r="38" fill="#fcd116"/><circle cx="285" cy="285" r="28" fill="none" stroke="#c98a00" stroke-width="5"/><text x="285" y="297" font-size="34" font-weight="800" text-anchor="middle" fill="#c98a00" font-family="DejaVu Sans">$</text>
<circle cx="60" cy="150" r="26" fill="#fcd116"/><circle cx="60" cy="150" r="18" fill="none" stroke="#c98a00" stroke-width="4"/>
<path d="M240 90l6 16 17 1-13 11 4 17-14-10-15 10 5-17-13-11 17-1z" fill="#fff"/>""",
"stage": """<polygon points="180,20 90,330 270,330" fill="rgba(255,255,255,.22)"/>
<ellipse cx="180" cy="326" rx="140" ry="18" fill="rgba(0,0,0,.28)"/>
<circle cx="180" cy="130" r="38" fill="#fff"/>
<path d="M105 320c0-70 30-135 75-135s75 65 75 135z" fill="#fff"/>
<rect x="212" y="122" width="12" height="62" rx="6" fill="#222" transform="rotate(18 218 150)"/><circle cx="229" cy="112" r="15" fill="#222" transform="rotate(18 218 150)"/>
<path d="M205 185l30-25" stroke="#fff" stroke-width="16" stroke-linecap="round"/>
<g fill="#fcd116"><circle cx="50" cy="90" r="10"/><rect x="58" y="40" width="5" height="52"/><path d="M63 40q28 8 30 30"/></g>
<g fill="#fff"><circle cx="305" cy="70" r="9"/><rect x="311" y="22" width="5" height="50"/></g>
<path d="M40 40l5 12 13 1-10 9 3 13-11-7-11 7 3-13-10-9 13-1z" fill="#fcd116"/>""",
"mic": """<rect x="140" y="40" width="80" height="140" rx="40" fill="#fff"/><path d="M110 150a70 70 0 0 0 140 0" stroke="#fff" stroke-width="14" fill="none" stroke-linecap="round"/>
<rect x="172" y="220" width="16" height="60" fill="#fff"/><rect x="125" y="280" width="110" height="16" rx="8" fill="#fff"/>
<g stroke="rgba(0,0,0,.2)" stroke-width="5"><path d="M150 80h60M150 105h60M150 130h60"/></g>
<g fill="#fcd116"><circle cx="55" cy="95" r="12"/><rect x="64" y="40" width="6" height="58"/><circle cx="305" cy="125" r="12"/><rect x="314" y="70" width="6" height="58"/></g>""",
"globe": """<circle cx="180" cy="180" r="130" fill="#fff"/><g fill="none" stroke="#1d6fb8" stroke-width="7"><ellipse cx="180" cy="180" rx="60" ry="130"/><path d="M50 180h260M65 115h230M65 245h230"/></g>
<path d="M150 90l30-20 35 10 10 35-30 10-15 30-30-10z" fill="#006b3f"/><path d="M190 200l40 5 10 40-30 25-25-30z" fill="#006b3f"/>
<polygon points="300,40 308,62 331,62 313,76 320,98 300,85 280,98 287,76 269,62 292,62" fill="#fcd116"/>""",
"film": """<rect x="40" y="130" width="280" height="190" rx="12" fill="#fff"/><rect x="40" y="80" width="280" height="55" rx="8" fill="#222"/>
<g fill="#fff"><polygon points="60,82 100,82 80,133 40,133"/><polygon points="130,82 170,82 150,133 110,133"/><polygon points="200,82 240,82 220,133 180,133"/><polygon points="270,82 310,82 290,133 250,133"/></g>
<polygon points="150,190 150,270 220,230" fill="#c8102e"/>""",
"ball": """<circle cx="180" cy="180" r="130" fill="#fff"/><polygon points="180,120 225,152 208,205 152,205 135,152" fill="#222"/>
<g stroke="#222" stroke-width="6"><path d="M180 120V55M225 152l55-25M208 205l35 50M152 205l-35 50M135 152L80 127"/></g>
<g fill="#222"><polygon points="180,40 205,58 195,86 165,86 155,58"/><polygon points="298,118 310,150 292,172 268,160 270,130"/><polygon points="62,118 90,130 92,160 68,172 50,150"/></g>""",
"tech": """<rect x="70" y="90" width="220" height="150" rx="12" fill="#fff"/><rect x="85" y="105" width="190" height="120" rx="6" fill="#0b3d91"/>
<path d="M40 250h280l-20 36H60z" fill="#fff"/><g fill="#fcd116"><path d="M130 140l-25 25 25 25" stroke="#fcd116" stroke-width="10" fill="none" stroke-linecap="round"/><path d="M230 140l25 25-25 25" stroke="#fcd116" stroke-width="10" fill="none" stroke-linecap="round"/></g>""",
"tv": """<rect x="45" y="80" width="270" height="190" rx="16" fill="#fff"/><rect x="62" y="97" width="236" height="156" rx="8" fill="#12263f"/>
<polygon points="160,140 160,210 220,175" fill="#fff"/><path d="M130 70l50 -40 50 40" stroke="#fff" stroke-width="8" fill="none" stroke-linecap="round"/><rect x="120" y="270" width="120" height="14" rx="7" fill="#fff"/>""",
"ticket": """<path d="M40 110h280v50a22 22 0 0 0 0 44v50H40v-50a22 22 0 0 0 0-44z" fill="#fff"/><path d="M240 110v140" stroke="#c8102e" stroke-width="5" stroke-dasharray="12 10"/>
<path d="M110 150l12 26 28 3-21 19 6 28-25-14-25 14 6-28-21-19 28-3z" fill="#fcd116"/>""",
}
def pick_art(title, cat):
    t = title.lower()
    if any(k in t for k in ("school", "ges ", "education", "teacher", "student", "exam", "wassce", "university")): return "school"
    if any(k in t for k in ("gold", "cedi", "fx", "bank", "economy", "price", "inflation", "budget")): return "gold"
    if any(k in t for k in ("concert", "live", "tour", "festival", "show")): return "stage"
    if any(k in t for k in ("ticket",)): return "ticket"
    return {"Education":"school","Business":"gold","Events":"ticket","News":"globe","Trending":"globe","Movies":"film","TV":"tv",
            "Sports":"ball","Tech":"tech","Afrobeats":"mic","Highlife":"mic","Hiplife":"mic","Gospel":"mic","Reviews":"mic","Celebrity":"stage","Lifestyle":"globe"}.get(cat,"mic")

def make(title, cat, out):
    a, b = PAL.get(cat, ("#c8102e", "#006b3f"))
    e = EMOJI.get(cat, "🎶")
    seed = int(hashlib.md5(title.encode()).hexdigest()[:6], 16)
    random.seed(seed)
    dots = "".join(
        f'<i style="left:{random.randint(2,96)}%;top:{random.randint(4,90)}%;width:{(s:=random.randint(30,150))}px;height:{s}px"></i>'
        for _ in range(9))
    size = 62 if len(title) < 40 else 52 if len(title) < 62 else 44 if len(title) < 90 else 38
    art = ART[pick_art(title, cat)]
    page = f"""<html><body style="margin:0"><div style="width:1200px;height:630px;position:relative;overflow:hidden;
    background:linear-gradient(135deg,{a},{b});font-family:'Anton','Impact','DejaVu Sans',sans-serif;color:#fff">
    <style>i{{position:absolute;border-radius:50%;background:rgba(255,255,255,.12)}}</style>{dots}
    <div style="position:absolute;top:0;left:0;right:0;height:16px;background:linear-gradient(90deg,#c8102e 33.3%,#fcd116 33.3% 66.6%,#006b3f 66.6%)"></div>
    <div style="position:absolute;left:60px;top:60px;background:#fff;color:#111;font:800 28px 'DejaVu Sans',sans-serif;padding:8px 22px;border-radius:40px">{e} {html.escape(cat.upper())}</div>
    <svg viewBox="0 0 360 360" style="position:absolute;right:40px;top:130px;width:400px;height:400px">{art}</svg>
    <div style="position:absolute;left:60px;right:480px;top:150px;bottom:130px;display:flex;align-items:center;
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
