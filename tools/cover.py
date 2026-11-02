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


DEFS = """<defs>
<linearGradient id="gold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff6b0"/><stop offset=".45" stop-color="#f3b61f"/><stop offset="1" stop-color="#9a5f00"/></linearGradient>
<linearGradient id="goldT" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#fffbd0"/><stop offset="1" stop-color="#f7cf47"/></linearGradient>
<linearGradient id="goldS" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#d79a12"/><stop offset="1" stop-color="#7a4a00"/></linearGradient>
<linearGradient id="brick" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e6cfa8"/><stop offset="1" stop-color="#b99a6c"/></linearGradient>
<linearGradient id="roof" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#b3392f"/><stop offset="1" stop-color="#6f1d18"/></linearGradient>
<linearGradient id="glass" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#d8f0ff"/><stop offset="1" stop-color="#5f9fd6"/></linearGradient>
<linearGradient id="wood" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#6b3f1e"/><stop offset="1" stop-color="#4a2a12"/></linearGradient>
<linearGradient id="beam" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".85"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
<linearGradient id="metal" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#555"/><stop offset=".45" stop-color="#e8e8e8"/><stop offset="1" stop-color="#3a3a3a"/></linearGradient>
<radialGradient id="sphere" cx=".35" cy=".3" r=".8"><stop offset="0" stop-color="#8fd3ff"/><stop offset=".55" stop-color="#1b6fc4"/><stop offset="1" stop-color="#08254f"/></radialGradient>
<radialGradient id="land" cx=".4" cy=".3" r=".9"><stop offset="0" stop-color="#58b957"/><stop offset="1" stop-color="#1c6a31"/></radialGradient>
<radialGradient id="ball" cx=".35" cy=".3" r=".85"><stop offset="0" stop-color="#fff"/><stop offset=".7" stop-color="#e5e5e5"/><stop offset="1" stop-color="#8d8d8d"/></radialGradient>
<linearGradient id="screen" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2f80ed"/><stop offset="1" stop-color="#0b2a66"/></linearGradient>
<linearGradient id="paper" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff5c2"/><stop offset="1" stop-color="#f1c232"/></linearGradient>
<filter id="sh" x="-20%" y="-20%" width="150%" height="150%"><feDropShadow dx="0" dy="8" stdDeviation="7" flood-color="#000" flood-opacity=".4"/></filter>
</defs>"""
ART = {
"school": """<ellipse cx="180" cy="325" rx="165" ry="16" fill="#000" opacity=".3"/>
<g filter="url(#sh)"><rect x="40" y="165" width="280" height="150" fill="url(#brick)"/>
<polygon points="22,170 180,70 338,170" fill="url(#roof)"/><polygon points="22,170 338,170 330,182 30,182" fill="#8f2a22"/>
<rect x="70" y="190" width="220" height="120" fill="#efe3c9" opacity=".35"/>
<g fill="#fff"><rect x="118" y="190" width="14" height="118"/><rect x="228" y="190" width="14" height="118"/><rect x="160" y="190" width="40" height="8"/></g>
<rect x="158" y="230" width="44" height="80" rx="22 22 0 0" fill="url(#wood)"/><rect x="179" y="232" width="2" height="78" fill="#2d1a0a"/>
<g fill="url(#glass)" stroke="#fff" stroke-width="4"><rect x="62" y="205" width="40" height="52"/><rect x="258" y="205" width="40" height="52"/></g>
<g stroke="#fff" stroke-width="3"><path d="M82 205v52M62 231h40M278 205v52M258 231h40"/></g>
<circle cx="180" cy="132" r="19" fill="#fff" stroke="#8f2a22" stroke-width="4"/><path d="M180 119v14l9 6" stroke="#222" stroke-width="3" fill="none" stroke-linecap="round"/>
<g fill="#d6d6d6"><rect x="130" y="312" width="100" height="8"/><rect x="118" y="320" width="124" height="8"/></g></g>
<rect x="178" y="22" width="4" height="52" fill="#ddd"/><polygon points="182,24 224,36 182,48" fill="#00a35c"/>""",
"gold": """<ellipse cx="180" cy="322" rx="150" ry="16" fill="#000" opacity=".32"/>
<g filter="url(#sh)">
<g><polygon points="30,290 70,262 200,262 160,290" fill="url(#goldT)"/><rect x="30" y="290" width="130" height="30" fill="url(#gold)"/><polygon points="160,290 200,262 200,292 160,320" fill="url(#goldS)"/></g>
<g><polygon points="170,290 210,262 340,262 300,290" fill="url(#goldT)"/><rect x="170" y="290" width="130" height="30" fill="url(#gold)"/><polygon points="300,290 340,262 340,292 300,320" fill="url(#goldS)"/></g>
<g><polygon points="100,236 140,208 270,208 230,236" fill="url(#goldT)"/><rect x="100" y="236" width="130" height="30" fill="url(#gold)"/><polygon points="230,236 270,208 270,238 230,266" fill="url(#goldS)"/></g>
<text x="165" y="258" font-size="20" font-weight="800" fill="#7a4a00" opacity=".8" text-anchor="middle" font-family="DejaVu Sans">GOLD 999.9</text>
<g><ellipse cx="290" cy="170" rx="46" ry="46" fill="url(#gold)"/><circle cx="290" cy="170" r="34" fill="none" stroke="#fff3a8" stroke-width="4"/><text x="290" y="185" font-size="42" font-weight="800" fill="#fff3a8" text-anchor="middle" font-family="DejaVu Sans">$</text></g></g>
<g fill="#fff"><path d="M70 120l5 14 14 5-14 5-5 14-5-14-14-5 14-5z"/><path d="M215 90l4 10 10 4-10 4-4 10-4-10-10-4 10-4z"/></g>""",
"stage": """<polygon points="70,0 120,0 230,330 20,330" fill="url(#beam)" opacity=".55"/><polygon points="290,0 240,0 130,330 340,330" fill="url(#beam)" opacity=".5"/>
<ellipse cx="180" cy="322" rx="170" ry="20" fill="#000" opacity=".45"/>
<g fill="#0c0a12"><circle cx="180" cy="116" r="36"/><circle cx="142" cy="100" r="22"/><circle cx="218" cy="100" r="22"/><circle cx="180" cy="82" r="26"/><circle cx="153" cy="88" r="20"/><circle cx="207" cy="88" r="20"/>
<rect x="166" y="140" width="28" height="36"/><path d="M100 326c0-80 30-150 80-150s80 70 80 150z"/><path d="M222 200l38-62" stroke="#0c0a12" stroke-width="22" stroke-linecap="round" fill="none"/><rect x="250" y="94" width="22" height="48" rx="11" transform="rotate(22 261 118)"/></g>
<path d="M214 116q-4 30 -2 60" stroke="#ffd98a" stroke-width="3" fill="none" opacity=".8"/><path d="M104 300q-4-70 36-120" stroke="#ffd98a" stroke-width="3" fill="none" opacity=".7"/>
<g fill="#0c0a12" opacity=".95"><circle cx="30" cy="318" r="18"/><circle cx="330" cy="316" r="18"/><path d="M12 330c0-30 10-50 18-50s18 20 18 50z"/><path d="M312 330c0-30 10-50 18-50s18 20 18 50z"/></g>
<g fill="#fff" opacity=".9"><circle cx="70" cy="40" r="7"/><circle cx="296" cy="30" r="7"/><path d="M120 60l3 8 8 3-8 3-3 8-3-8-8-3 8-3z"/><path d="M262 70l3 8 8 3-8 3-3 8-3-8-8-3 8-3z"/></g>""",
"mic": """<ellipse cx="180" cy="326" rx="110" ry="14" fill="#000" opacity=".35"/>
<g filter="url(#sh)"><rect x="168" y="215" width="24" height="95" fill="url(#metal)"/><rect x="110" y="304" width="140" height="16" rx="8" fill="url(#metal)"/>
<path d="M105 140a75 75 0 0 0 150 0" fill="none" stroke="url(#metal)" stroke-width="14" stroke-linecap="round"/>
<rect x="125" y="36" width="110" height="180" rx="55" fill="url(#metal)"/><rect x="133" y="44" width="94" height="164" rx="47" fill="#222"/>
<g stroke="#8a8a8a" stroke-width="2" opacity=".8"><path d="M140 70h80M138 90h84M138 110h84M138 130h84M138 150h84M140 170h80M144 190h72"/><path d="M160 50v150M180 46v160M200 50v150"/></g>
<rect x="125" y="140" width="110" height="12" fill="#c8102e"/></g>""",
"globe": """<ellipse cx="180" cy="334" rx="110" ry="12" fill="#000" opacity=".4"/>
<circle cx="180" cy="185" r="142" fill="#5ab4ff" opacity=".25"/>
<g filter="url(#sh)"><circle cx="180" cy="185" r="130" fill="url(#sphere)"/>
<g fill="url(#land)"><path d="M118 98l48-26 46 16 14 36-40 12-24 40-42-16z"/><path d="M196 220l54 6 14 44-38 36-34-38z"/><path d="M78 205l40 14-6 38-34-16z"/></g>
<g fill="none" stroke="#fff" stroke-width="1.5" opacity=".25"><ellipse cx="180" cy="185" rx="130" ry="50"/><ellipse cx="180" cy="185" rx="50" ry="130"/></g>
<ellipse cx="135" cy="115" rx="55" ry="32" fill="#fff" opacity=".22" transform="rotate(-30 135 115)"/></g>
<circle cx="150" cy="150" r="5" fill="#fcd116"/>""",
"film": """<ellipse cx="180" cy="330" rx="150" ry="14" fill="#000" opacity=".35"/>
<g filter="url(#sh)"><rect x="40" y="140" width="280" height="180" rx="10" fill="#1c1c1f"/>
<rect x="52" y="152" width="256" height="156" fill="none" stroke="#fff" stroke-width="2" opacity=".35"/>
<g fill="#fff" opacity=".85" font-family="DejaVu Sans" font-weight="800" font-size="20"><text x="62" y="186">ROLL</text><text x="62" y="228">SCENE</text><text x="62" y="270">TAKE</text></g>
<g stroke="#fff" stroke-width="2" opacity=".5"><path d="M150 168h140M150 210h140M150 252h140"/></g>
<g transform="rotate(-8 60 140)"><rect x="40" y="96" width="280" height="46" fill="#1c1c1f"/><g fill="#f4f4f4"><polygon points="52,96 100,96 76,142 28,142"/><polygon points="130,96 178,96 154,142 106,142"/><polygon points="208,96 256,96 232,142 184,142"/><polygon points="286,96 334,96 310,142 262,142"/></g></g></g>""",
"ball": """<ellipse cx="180" cy="334" rx="110" ry="12" fill="#000" opacity=".4"/>
<g filter="url(#sh)"><circle cx="180" cy="185" r="132" fill="url(#ball)"/>
<polygon points="180,128 222,158 206,208 154,208 138,158" fill="#1d1d1d"/>
<g fill="#1d1d1d"><polygon points="180,56 206,74 196,102 164,102 154,74"/><polygon points="296,120 312,152 294,176 268,162 272,132"/><polygon points="64,120 92,132 96,162 70,176 52,152"/><polygon points="130,300 160,282 190,300 178,328 142,328"/><polygon points="240,300 262,284 286,300 276,324 250,324"/></g>
<g stroke="#9a9a9a" stroke-width="3" fill="none"><path d="M180 128V102M222 158l46 4M206 208l24 76M154 208l-24 76M138 158l-46 4"/></g></g>""",
"tech": """<ellipse cx="180" cy="330" rx="160" ry="12" fill="#000" opacity=".35"/>
<g filter="url(#sh)"><rect x="64" y="84" width="232" height="156" rx="12" fill="#2a2a2e"/><rect x="76" y="96" width="208" height="132" rx="4" fill="url(#screen)"/>
<g fill="#fff" opacity=".9" font-family="DejaVu Sans" font-weight="800"><text x="96" y="140" font-size="26">&lt;/&gt;</text></g>
<g stroke="#cfe3ff" stroke-width="6" opacity=".7" stroke-linecap="round"><path d="M96 168h90M96 188h130M96 208h70"/></g>
<path d="M28 246h304l-20 44H48z" fill="url(#metal)"/><rect x="150" y="256" width="60" height="6" rx="3" fill="#777"/></g>""",
"tv": """<ellipse cx="180" cy="334" rx="130" ry="12" fill="#000" opacity=".35"/>
<g filter="url(#sh)"><rect x="36" y="70" width="288" height="200" rx="14" fill="#222"/><rect x="48" y="82" width="264" height="176" rx="6" fill="url(#screen)"/>
<polygon points="48,82 180,82 110,258 48,258" fill="#fff" opacity=".08"/>
<polygon points="160,130 160,210 226,170" fill="#fff" opacity=".92"/>
<rect x="150" y="270" width="60" height="30" fill="url(#metal)"/><rect x="110" y="298" width="140" height="12" rx="6" fill="url(#metal)"/></g>""",
"ticket": """<ellipse cx="180" cy="324" rx="150" ry="12" fill="#000" opacity=".3"/>
<g filter="url(#sh)" transform="rotate(-6 180 190)"><path d="M30 100h300v58a26 26 0 0 0 0 52v58H30v-58a26 26 0 0 0 0-52z" fill="url(#paper)"/><path d="M246 100v168" stroke="#b8860b" stroke-width="3" stroke-dasharray="10 8"/>
<g fill="#7a4a00" font-family="DejaVu Sans" font-weight="800"><text x="50" y="160" font-size="34">ADMIT</text><text x="50" y="200" font-size="34">ONE</text></g>
<g fill="#7a4a00"><rect x="262" y="130" width="4" height="70"/><rect x="272" y="130" width="8" height="70"/><rect x="286" y="130" width="3" height="70"/><rect x="295" y="130" width="6" height="70"/><rect x="306" y="130" width="3" height="70"/></g></g>""",
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
    <svg viewBox="0 0 360 360" style="position:absolute;right:40px;top:120px;width:410px;height:410px">{DEFS}{art}</svg>
    <div style="position:absolute;left:60px;right:480px;top:150px;bottom:130px;display:flex;align-items:center;
      font:800 {size}px/1.12 'DejaVu Sans',sans-serif;text-shadow:0 4px 18px rgba(0,0,0,.35)">{html.escape(title)}</div>
    <div style="position:absolute;left:60px;bottom:40px;font:800 38px 'DejaVu Sans',sans-serif;letter-spacing:1px">HOTTEST GIST <span style="background:#006b3f;padding:2px 14px;border-radius:6px">GH</span></div>
    <div style="position:absolute;right:60px;bottom:48px;font:700 26px 'DejaVu Sans',sans-serif;opacity:.9">hottest-gist-gh.hodisgood24.workers.dev</div>
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
