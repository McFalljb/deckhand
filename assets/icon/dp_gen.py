# Deckhand "D porthole" concepts: the letter D is a ship's porthole; its counter is glass showing waves.
# Usage: python3 dp_gen.py <outdir>    -> writes dp-1.svg .. dp-6.svg (1024, Big Sur 824 body at 100,100)
import math, os, sys
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

def squircle(x0=100, y0=100, size=824, R=300, n=4.6, steps=24):
    corners = [(x0 + size - R, y0 + size - R, 0), (x0 + R, y0 + size - R, 1),
               (x0 + R, y0 + R, 2), (x0 + size - R, y0 + R, 3)]
    pts = []
    for cx, cy, q in corners:
        for i in range(steps + 1):
            t = (q + i / steps) * math.pi / 2
            c, s = math.cos(t), math.sin(t)
            pts.append(f"{cx + R * math.copysign(abs(c) ** (2 / n), c):.1f},"
                       f"{cy + R * math.copysign(abs(s) ** (2 / n), s):.1f}")
    return "M" + " L".join(pts) + " Z"
BODY = squircle()

# ---- D geometry -------------------------------------------------------------
# Outer D: stem at x=L, flat top/bottom to x=cx, then a half circle of radius R about (cx, cy).
CY = 512
def dpath(L, cx, R, rc, cy=CY):
    """D outline with left corners rounded by rc."""
    top, bot = cy - R, cy + R
    return (f"M{L+rc},{top} L{cx},{top} A{R},{R} 0 0 1 {cx},{bot} L{L+rc},{bot} "
            f"Q{L},{bot} {L},{bot-rc} L{L},{top+rc} Q{L},{top} {L+rc},{top} Z")

class D:
    def __init__(s, L=244, cx=462, R=322, stem=118, rim=96, rc=34, rci=26):
        s.L, s.cx, s.R, s.stem, s.rim = L, cx, R, stem, rim
        s.outer = dpath(L, cx, R, rc)
        s.iL, s.iR = L + stem, R - rim
        s.inner = dpath(s.iL, cx, s.iR, rci)
        s.top, s.bot = CY - R, CY + R
        s.itop, s.ibot = CY - s.iR, CY + s.iR
        s.right = cx + R
        s.iright = cx + s.iR
    def rivets(s, r=15, fill="#7a5216", hl="#fff3c4", n_arc=5, stem_n=4, flat=True):
        mR = s.R - s.rim / 2
        pts = [(s.cx + mR * math.cos(math.radians(a)), CY + mR * math.sin(math.radians(a)))
               for a in [(-90 + 180 * (i + 0.5) / n_arc) for i in range(n_arc)]]
        mx = s.L + s.stem / 2
        if flat:
            for x in (s.iL + 6, ):
                pts += [(x + (s.cx - x) * 0.5, CY - mR), (x + (s.cx - x) * 0.5, CY + mR)]
        for i in range(stem_n):
            pts.append((mx, s.top + 58 + (s.bot - s.top - 116) * i / (stem_n - 1)))
        out = ""
        for x, y in pts:
            out += (f'<circle cx="{x:.1f}" cy="{y+3:.1f}" r="{r}" fill="#000" fill-opacity="0.28"/>'
                    f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{fill}"/>'
                    f'<circle cx="{x-r*0.3:.1f}" cy="{y-r*0.3:.1f}" r="{r*0.42:.1f}" fill="{hl}" fill-opacity="0.75"/>')
        return out

def wave(y, amp, wl, phase=0, x0=200, x1=860, bottom=900, steps=80):
    pts = []
    for i in range(steps + 1):
        x = x0 + (x1 - x0) * i / steps
        pts.append(f"{x:.1f},{y + amp * math.sin(2 * math.pi * (x / wl) + phase):.1f}")
    return f"M{x0},{bottom} L" + " L".join(pts) + f" L{x1},{bottom} Z"

def wave_line(y, amp, wl, phase=0, x0=200, x1=860, steps=80):
    pts = []
    for i in range(steps + 1):
        x = x0 + (x1 - x0) * i / steps
        pts.append(f"{x:.1f},{y + amp * math.sin(2 * math.pi * (x / wl) + phase):.1f}")
    return "M" + " L".join(pts)

def svg(defs, tile, art):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <filter id="drop" x="-20%" y="-20%" width="140%" height="140%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/>
    <feComponentTransfer><feFuncA type="linear" slope="0.30"/></feComponentTransfer>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="dsh" x="-20%" y="-20%" width="140%" height="140%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="10"/><feOffset dy="10"/>
    <feComponentTransfer><feFuncA type="linear" slope="0.35"/></feComponentTransfer>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <clipPath id="body"><path d="{BODY}"/></clipPath>
  <linearGradient id="tilerim" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.40"/><stop offset="0.5" stop-color="#ffffff" stop-opacity="0.05"/><stop offset="1" stop-color="#000000" stop-opacity="0.12"/>
  </linearGradient>
{defs}
</defs>
<g filter="url(#drop)"><path d="{BODY}" fill="{tile}"/></g>
<g clip-path="url(#body)">
{art}
</g>
<path d="{BODY}" fill="none" stroke="url(#tilerim)" stroke-width="5"/>
</svg>
'''

def glass_hl(d, op=0.22):
    # curved specular sweep across the upper-left of the glass
    x0, y0 = d.iL + 26, d.itop + 40
    return (f'<path d="M{x0},{y0+150} Q{x0+10},{y0+10} {x0+170},{y0} Q{x0+60},{y0+40} {x0+34},{y0+170} Z" '
            f'fill="#fff" fill-opacity="{op}"/>')

# ---- 1. Flat modern, day: solid navy D, layered flat waves, pale sky tile -----
def v1():
    d = D()
    defs = f'''<linearGradient id="t1" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f4f1ea"/><stop offset="1" stop-color="#e3ddd0"/></linearGradient>
  <clipPath id="g1"><path d="{d.inner}"/></clipPath>'''
    art = f'''<path d="{d.outer}" fill="#14365c"/>
<g clip-path="url(#g1)">
  <rect x="300" y="150" width="500" height="700" fill="#8fd0f2"/>
  <circle cx="{d.cx+60}" cy="{d.itop+105}" r="44" fill="#ffd36b"/>
  <path d="{wave(560, 16, 150, 0.6)}" fill="#3aa0d8"/>
  <path d="{wave(622, 18, 170, 2.4)}" fill="#1f7fc0"/>
  <path d="{wave(690, 18, 190, 4.2)}" fill="#155f99"/>
</g>
<path d="{d.inner}" fill="none" stroke="#2f6aa3" stroke-width="20"/>'''
    return svg(defs, "url(#t1)", art)

# ---- 2. Riveted brass D with a hinge stem on a navy hull; curling wave; glass highlight
def v2():
    d = D()
    defs = f'''<linearGradient id="t2" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#245d8c"/><stop offset="1" stop-color="#112f4f"/></linearGradient>
  <linearGradient id="brass" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffe29a"/><stop offset="0.45" stop-color="#e0aa48"/><stop offset="1" stop-color="#9a6620"/></linearGradient>
  <linearGradient id="sky2" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6cc3f0"/><stop offset="1" stop-color="#cdeefc"/></linearGradient>
  <linearGradient id="sea2" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1c86c8"/><stop offset="1" stop-color="#0d4f86"/></linearGradient>
  <clipPath id="g2"><path d="{d.inner}"/></clipPath>'''
    # curling wave: swell rising from left, crest curling over to the right
    curl = (f"M300,760 L300,600 C360,590 420,560 470,500 C510,452 560,420 612,428 "
            f"C664,436 690,480 672,520 C658,552 618,556 604,530 C594,510 610,490 630,496 "
            f"C606,470 562,478 548,520 C530,575 580,640 700,650 L800,660 L800,760 Z")
    foam = (f"M612,428 C664,436 690,480 672,520 C658,552 618,556 604,530 C594,510 610,490 630,496 "
            f"C640,470 610,452 586,456 C620,446 650,460 612,428 Z")
    art = f'''<g filter="url(#dsh)"><path d="{d.outer}" fill="url(#brass)"/></g>
<path d="{d.outer}" fill="none" stroke="#7a5216" stroke-opacity="0.55" stroke-width="6"/>
<path d="{d.inner}" fill="none" stroke="#6b4512" stroke-width="22"/>
<g clip-path="url(#g2)">
  <rect x="300" y="150" width="500" height="700" fill="url(#sky2)"/>
  <path d="{wave(610, 10, 120, 1)}" fill="#3a9ad6"/>
  <path d="{curl}" fill="url(#sea2)"/>
  <path d="{foam}" fill="#ffffff"/>
  <path d="{wave(690, 12, 140, 3)}" fill="#0b3f6e"/>
  {glass_hl(d, 0.28)}
</g>
<path d="{d.inner}" fill="none" stroke="#3e2808" stroke-opacity="0.35" stroke-width="6"/>
{d.rivets(r=16, fill="#b07a2a", hl="#fff0bf")}'''
    return svg(defs, "url(#t2)", art)

# ---- 3. Dusk: copper D, calm horizon, setting sun with reflection; tiny > on the horizon
def v3():
    d = D()
    defs = f'''<linearGradient id="t3" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2b2550"/><stop offset="1" stop-color="#171430"/></linearGradient>
  <linearGradient id="cop" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffc58a"/><stop offset="0.5" stop-color="#d9824a"/><stop offset="1" stop-color="#8e4a24"/></linearGradient>
  <linearGradient id="sky3" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4b3f8c"/><stop offset="0.55" stop-color="#e0708a"/><stop offset="1" stop-color="#ffb070"/></linearGradient>
  <linearGradient id="sea3" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3e3a78"/><stop offset="1" stop-color="#1c1a40"/></linearGradient>
  <clipPath id="g3"><path d="{d.inner}"/></clipPath>'''
    hz = 560
    refl = "".join(f'<rect x="{d.cx+40-w/2:.0f}" y="{hz+18+i*30}" width="{w:.0f}" height="10" rx="5" fill="#ffc77a" fill-opacity="{0.85-i*0.15:.2f}"/>'
                   for i, w in enumerate([150, 110, 74, 44]))
    art = f'''<g filter="url(#dsh)"><path d="{d.outer}" fill="url(#cop)"/></g>
<path d="{d.inner}" fill="none" stroke="#5e2c12" stroke-width="20"/>
<g clip-path="url(#g3)">
  <rect x="300" y="150" width="500" height="700" fill="url(#sky3)"/>
  <circle cx="{d.cx+40}" cy="{hz}" r="86" fill="#ffd27a"/>
  <rect x="300" y="{hz}" width="500" height="300" fill="url(#sea3)"/>
  {refl}
  {glass_hl(d, 0.16)}
</g>
{d.rivets(r=14, fill="#a85a2c", hl="#ffd9b0")}'''
    return svg(defs, "url(#t3)", art)

# ---- 4. Night: steel D, moon is a block cursor, layered dark waves, stars --------
def v4():
    d = D()
    defs = f'''<linearGradient id="t4" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1d2b44"/><stop offset="1" stop-color="#0b1220"/></linearGradient>
  <linearGradient id="steel" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f1f4f8"/><stop offset="0.5" stop-color="#aab4c2"/><stop offset="1" stop-color="#5d6878"/></linearGradient>
  <linearGradient id="sky4" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0d1630"/><stop offset="1" stop-color="#25407a"/></linearGradient>
  <clipPath id="g4"><path d="{d.inner}"/></clipPath>
  <filter id="glow4" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="14"/></filter>'''
    cur_x, cur_y = d.cx + 30, d.itop + 92
    stars = "".join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="#dfe8ff" fill-opacity="0.85"/>' for x, y, r in
                    [(400, 330, 5), (448, 400, 4), (560, 352, 4), (630, 450, 3), (410, 470, 3)])
    art = f'''<g filter="url(#dsh)"><path d="{d.outer}" fill="url(#steel)"/></g>
<path d="{d.inner}" fill="none" stroke="#3b4452" stroke-width="20"/>
<g clip-path="url(#g4)">
  <rect x="300" y="150" width="500" height="700" fill="url(#sky4)"/>
  {stars}
  <rect x="{cur_x-8}" y="{cur_y-8}" width="70" height="104" rx="8" fill="#9ec1ff" filter="url(#glow4)" opacity="0.8"/>
  <rect x="{cur_x}" y="{cur_y}" width="54" height="88" rx="6" fill="#e8f0ff"/>
  <path d="M{cur_x+14},{580} L{cur_x+40},{580}" stroke="#bcd3ff" stroke-opacity="0.6" stroke-width="10" stroke-linecap="round"/>
  <path d="{wave(560, 12, 140, 0.4)}" fill="#2c5aa0"/>
  <path d="{wave_line(560, 12, 140, 0.4)}" fill="none" stroke="#9ec1ff" stroke-opacity="0.5" stroke-width="6"/>
  <path d="{wave(626, 16, 170, 2.2)}" fill="#1c3f78"/>
  <path d="{wave(694, 18, 200, 4.1)}" fill="#11284f"/>
  <rect x="{cur_x+6}" y="590" width="42" height="8" rx="4" fill="#e8f0ff" fill-opacity="0.55"/>
  {glass_hl(d, 0.12)}
</g>
{d.rivets(r=14, fill="#7d8796", hl="#ffffff")}'''
    return svg(defs, "url(#t4)", art)

# ---- 5. Flat bold: white D on ocean-blue tile, single wave, a tiny >_ in the sky --
def v5():
    d = D(stem=128, rim=104)
    defs = f'''<linearGradient id="t5" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2f8fe0"/><stop offset="1" stop-color="#1747a8"/></linearGradient>
  <clipPath id="g5"><path d="{d.inner}"/></clipPath>'''
    art = f'''<path d="{d.outer}" fill="#ffffff"/>
<g clip-path="url(#g5)">
  <rect x="300" y="150" width="500" height="700" fill="#0f2a5e"/>
  <path d="M{d.iL+44},{d.itop+70} L{d.iL+84},{d.itop+104} L{d.iL+44},{d.itop+138}" fill="none" stroke="#7fd4ff" stroke-width="20" stroke-linecap="round" stroke-linejoin="round"/>
  <rect x="{d.iL+100}" y="{d.itop+126}" width="50" height="16" rx="6" fill="#7fd4ff"/>
  <path d="{wave(560, 26, 210, 0.2)}" fill="#26b6e8"/>
  <path d="{wave(650, 22, 190, 2.6)}" fill="#1a85c9"/>
</g>
<path d="{d.inner}" fill="none" stroke="#cfe2f6" stroke-width="18"/>'''
    return svg(defs, "url(#t5)", art)

# ---- 6. Dimensional enamel: thick glossy navy D with brass inner bezel, big Hokusai-ish curl, day
def v6():
    d = D(stem=124, rim=100)
    defs = f'''<linearGradient id="t6" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff6e6"/><stop offset="1" stop-color="#f1dfc0"/></linearGradient>
  <linearGradient id="enam" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2a5f96"/><stop offset="1" stop-color="#0f2c50"/></linearGradient>
  <linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.24"/><stop offset="0.5" stop-color="#fff" stop-opacity="0"/></linearGradient>
  <linearGradient id="bez" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffe7a8"/><stop offset="1" stop-color="#b77d2c"/></linearGradient>
  <linearGradient id="sky6" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8fd2f0"/><stop offset="1" stop-color="#e6f6fc"/></linearGradient>
  <clipPath id="g6"><path d="{d.inner}"/></clipPath>'''
    # wave: big swell from the right, crest curls over to the left; the barrel under the lip shows sky
    body_w = ("M300,800 L300,664 L380,664 C462,664 524,626 546,572 C562,528 530,496 486,522 "
              "C474,462 546,410 628,410 C700,410 748,436 800,468 L800,800 Z")
    foam = ("M486,522 C474,462 546,410 628,410 C700,410 748,436 800,468 L800,506 "
            "C748,474 700,452 632,452 C570,452 520,478 486,522 Z")
    art = f'''<g filter="url(#dsh)"><path d="{d.outer}" fill="url(#enam)"/></g>
<path d="{d.outer}" fill="url(#gloss)"/>
<path d="{d.inner}" fill="none" stroke="url(#bez)" stroke-width="36"/>
<g clip-path="url(#g6)">
  <rect x="300" y="150" width="500" height="700" fill="url(#sky6)"/>
  <path d="{wave(650, 10, 130, 1.2)}" fill="#5fb3d6"/>
  <path d="{body_w}" fill="#1d6fa8"/>
  <path d="{foam}" fill="#ffffff"/>
  <path d="M488,518 C474,560 512,584 536,560 C552,542 540,520 520,524 C508,527 508,542 518,546" fill="none" stroke="#ffffff" stroke-width="15" stroke-linecap="round"/>
  <path d="{wave(712, 14, 150, 3.4)}" fill="#0f4d80"/>
  {glass_hl(d, 0.30)}
</g>
<path d="{d.inner}" fill="none" stroke="#5a3a0e" stroke-opacity="0.35" stroke-width="4"/>'''
    return svg(defs, "url(#t6)", art)

for n, fn in enumerate([v1, v2, v3, v4, v5, v6], 1):
    open(os.path.join(OUT, f"dp-{n}.svg"), "w").write(fn())
print("ok")
