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
"school": """<rect x="50" y="150" width="260" height="160" rx="14" fill="#fff"/>
<polygon points="28,158 180,62 332,158" fill="#fcd116"/>
<rect x="150" y="232" width="60" height="78" rx="30 30 4 4" fill="#ff5a5f"/><circle cx="198" cy="274" r="5" fill="#fcd116"/>
<circle cx="115" cy="205" r="26" fill="#bde0ff"/><circle cx="245" cy="205" r="26" fill="#bde0ff"/>
<circle cx="115" cy="205" r="9" fill="#1a1a1a"/><circle cx="245" cy="205" r="9" fill="#1a1a1a"/><circle cx="118" cy="201" r="3" fill="#fff" stroke="none"/><circle cx="248" cy="201" r="3" fill="#fff" stroke="none"/>
<path d="M165 215q15 14 30 0" fill="none"/>
<circle cx="180" cy="122" r="20" fill="#fff"/><path d="M180 109v14l9 6" fill="none"/>
<path d="M180 62V18" fill="none"/><path d="M180 20l46 14-46 14z" fill="#00a35c"/>
<rect x="238" y="262" width="74" height="52" rx="6" fill="#ff7a00" transform="rotate(-10 275 288)"/><rect x="246" y="270" width="58" height="36" rx="4" fill="#fff" transform="rotate(-10 275 288)"/>
<path d="M258 288l40-7" fill="none" stroke-width="4"/>
<path d="M300 90l7 16 17 2-13 12 4 17-15-9-15 9 4-17-13-12 17-2z" fill="#fff"/>""",
"gold": """<polygon points="30,300 62,232 200,232 232,300" fill="#ffd21f"/>
<polygon points="110,232 142,164 280,164 312,232" fill="#ffb800"/>
<polygon points="62,164 92,100 214,100 184,164" fill="#ffe56b" transform="translate(50 6)"/>
<circle cx="130" cy="268" r="6" fill="#1a1a1a"/><circle cx="165" cy="268" r="6" fill="#1a1a1a"/><path d="M130 281q17 15 35 0" fill="none"/>
<circle cx="282" cy="288" r="40" fill="#ffd21f"/><circle cx="282" cy="288" r="27" fill="#ffe56b"/>
<path d="M282 270v36M271 278q11-8 22 0M271 298q11 8 22 0" fill="none" stroke-width="5"/>
<circle cx="52" cy="150" r="28" fill="#ffd21f"/><circle cx="43" cy="146" r="4" fill="#1a1a1a" stroke="none"/><circle cx="61" cy="146" r="4" fill="#1a1a1a" stroke="none"/><path d="M40 158q12 12 24 0" fill="none" stroke-width="4"/>
<path d="M250 60l8 20 21 2-16 14 5 21-18-12-18 12 5-21-16-14 21-2z" fill="#fff"/>
<path d="M310 150l4 9 10 1-8 6 3 10-9-6-9 6 3-10-8-6 10-1z" fill="#fff" stroke-width="4"/>""",
"stage": """<polygon points="180,10 70,336 290,336" fill="rgba(255,255,255,.25)" stroke="none"/>
<ellipse cx="180" cy="334" rx="130" ry="16" fill="rgba(0,0,0,.3)" stroke="none"/>
<path d="M92 330c0-78 36-128 88-128s88 50 88 128z" fill="#ff3d5a"/>
<path d="M130 330c10-40 25-70 50-80 25 10 40 40 50 80z" fill="#ffd21f"/>
<rect x="165" y="190" width="30" height="26" rx="8" fill="#8d5524"/>
<circle cx="180" cy="140" r="52" fill="#a9682d"/>
<circle cx="136" cy="104" r="24" fill="#2b1608"/><circle cx="224" cy="104" r="24" fill="#2b1608"/><circle cx="180" cy="86" r="30" fill="#2b1608"/><circle cx="150" cy="92" r="22" fill="#2b1608"/><circle cx="210" cy="92" r="22" fill="#2b1608"/>
<circle cx="160" cy="138" r="8" fill="#fff"/><circle cx="200" cy="138" r="8" fill="#fff"/><circle cx="162" cy="140" r="4" fill="#1a1a1a" stroke="none"/><circle cx="202" cy="140" r="4" fill="#1a1a1a" stroke="none"/>
<path d="M162 162q18 24 38 0z" fill="#7a1f2b"/><circle cx="143" cy="158" r="8" fill="#ff8aa0" stroke="none"/><circle cx="217" cy="158" r="8" fill="#ff8aa0" stroke="none"/>
<path d="M215 215l32-38" stroke-width="22" stroke="#1a1a1a" fill="none"/><path d="M215 215l32-38" stroke-width="12" stroke="#a9682d" fill="none"/>
<rect x="224" y="150" width="16" height="44" rx="8" fill="#555" transform="rotate(28 232 172)"/><circle cx="251" cy="144" r="17" fill="#ff5a5f" transform="rotate(28 232 172)"/>
<path d="M52 70q0-26 24-26v62" fill="none" stroke-width="7" stroke="#1a1a1a"/><circle cx="46" cy="106" r="15" fill="#ffd21f"/><rect x="68" y="44" width="8" height="58" fill="#ffd21f"/>
<circle cx="312" cy="96" r="14" fill="#fff"/><rect x="320" y="44" width="8" height="56" fill="#fff"/>
<path d="M300 220l7 16 17 2-13 12 4 17-15-9-15 9 4-17-13-12 17-2z" fill="#ffd21f"/>""",
"mic": """<rect x="130" y="30" width="100" height="160" rx="50" fill="#ff5a5f"/>
<path d="M104 150a76 76 0 0 0 152 0" fill="none" stroke-width="16"/><path d="M104 150a76 76 0 0 0 152 0" fill="none" stroke="#fff" stroke-width="6"/>
<rect x="168" y="224" width="24" height="56" fill="#ffd21f"/><rect x="116" y="278" width="128" height="22" rx="11" fill="#00a35c"/>
<circle cx="160" cy="96" r="9" fill="#fff"/><circle cx="200" cy="96" r="9" fill="#fff"/><circle cx="162" cy="98" r="4" fill="#1a1a1a" stroke="none"/><circle cx="202" cy="98" r="4" fill="#1a1a1a" stroke="none"/>
<path d="M160 128q20 20 40 0" fill="#7a1f2b"/>
<circle cx="52" cy="100" r="14" fill="#ffd21f"/><rect x="62" y="40" width="8" height="62" fill="#ffd21f"/><circle cx="310" cy="140" r="14" fill="#fff"/><rect x="320" y="80" width="8" height="62" fill="#fff"/>""",
"globe": """<circle cx="180" cy="190" r="130" fill="#4db8ff"/>
<path d="M120 100l50-24 50 20 12 40-46 12-24 44-44-16z" fill="#2ecc71"/><path d="M200 220l56 6 14 48-40 36-34-38z" fill="#2ecc71"/><path d="M80 210l38 12-6 40-32-18z" fill="#2ecc71"/>
<circle cx="145" cy="170" r="14" fill="#fff"/><circle cx="215" cy="170" r="14" fill="#fff"/><circle cx="148" cy="172" r="6" fill="#1a1a1a" stroke="none"/><circle cx="218" cy="172" r="6" fill="#1a1a1a" stroke="none"/>
<path d="M150 214q30 32 60 0z" fill="#7a1f2b"/>
<polygon points="300,28 309,52 334,53 315,69 321,93 300,79 279,93 285,69 266,53 291,52" fill="#ffd21f"/>""",
"film": """<rect x="36" y="130" width="288" height="190" rx="16" fill="#fff"/>
<rect x="36" y="76" width="288" height="58" rx="10" fill="#2b2b2b"/>
<polygon points="56,78 104,78 84,132 36,132" fill="#ffd21f"/><polygon points="134,78 182,78 162,132 114,132" fill="#ff5a5f"/><polygon points="212,78 260,78 240,132 192,132" fill="#ffd21f"/><polygon points="290,78 330,78 320,132 270,132" fill="#ff5a5f"/>
<circle cx="130" cy="210" r="11" fill="#1a1a1a"/><circle cx="230" cy="210" r="11" fill="#1a1a1a"/><circle cx="134" cy="206" r="4" fill="#fff" stroke="none"/><circle cx="234" cy="206" r="4" fill="#fff" stroke="none"/>
<path d="M140 250q40 40 80 0z" fill="#7a1f2b"/>""",
"ball": """<circle cx="180" cy="190" r="132" fill="#fff"/>
<polygon points="180,128 226,160 208,214 152,214 134,160" fill="#2b2b2b"/>
<path d="M180 128V62M226 160l58-26M208 214l34 54M152 214l-34 54M134 160L76 134" fill="none"/>
<polygon points="180,52 208,70 198,100 162,100 152,70" fill="#2b2b2b"/><polygon points="300,126 316,160 296,184 268,170 272,138" fill="#2b2b2b"/><polygon points="60,126 88,138 92,170 64,184 44,160" fill="#2b2b2b"/>
<circle cx="150" cy="182" r="7" fill="#fff" stroke="none"/><circle cx="210" cy="182" r="7" fill="#fff" stroke="none"/>""",
"tech": """<rect x="64" y="80" width="232" height="164" rx="16" fill="#fff"/><rect x="82" y="98" width="196" height="128" rx="8" fill="#2d6cdf"/>
<path d="M30 252h300l-24 40H54z" fill="#ffd21f"/>
<circle cx="145" cy="150" r="12" fill="#fff"/><circle cx="215" cy="150" r="12" fill="#fff"/><circle cx="147" cy="152" r="5" fill="#1a1a1a" stroke="none"/><circle cx="217" cy="152" r="5" fill="#1a1a1a" stroke="none"/>
<path d="M150 182q30 28 60 0" fill="none" stroke="#fff" stroke-width="7"/>""",
"tv": """<rect x="40" y="80" width="280" height="196" rx="22" fill="#ff5a5f"/><rect x="60" y="100" width="240" height="156" rx="12" fill="#bfe9ff"/>
<circle cx="140" cy="160" r="13" fill="#fff"/><circle cx="220" cy="160" r="13" fill="#fff"/><circle cx="142" cy="162" r="6" fill="#1a1a1a" stroke="none"/><circle cx="222" cy="162" r="6" fill="#1a1a1a" stroke="none"/>
<path d="M145 200q35 34 70 0z" fill="#7a1f2b"/>
<path d="M130 72l50-44 50 44" fill="none" stroke-width="8"/><rect x="110" y="276" width="140" height="18" rx="9" fill="#ffd21f"/>""",
"ticket": """<path d="M30 100h300v56a26 26 0 0 0 0 52v56H30v-56a26 26 0 0 0 0-52z" fill="#ffd21f"/><path d="M246 100v164" stroke-dasharray="14 12" fill="none"/>
<circle cx="120" cy="170" r="11" fill="#1a1a1a"/><circle cx="184" cy="170" r="11" fill="#1a1a1a"/><circle cx="123" cy="166" r="4" fill="#fff" stroke="none"/><circle cx="187" cy="166" r="4" fill="#fff" stroke="none"/>
<path d="M120 198q32 32 64 0z" fill="#7a1f2b"/>
<path d="M290 40l8 18 19 2-14 13 4 19-17-10-17 10 4-19-14-13 19-2z" fill="#fff"/>""",
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
    <svg viewBox="0 0 360 360" style="position:absolute;right:40px;top:120px;width:410px;height:410px"><g stroke="#1a1a1a" stroke-width="6" stroke-linejoin="round" stroke-linecap="round">{art}</g></svg>
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
