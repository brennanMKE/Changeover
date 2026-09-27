#!/usr/bin/env python3
"""Turn docs/screens/manifest.json into docs/screens/index.html.

The manifest is written by ScreenshotHarnessTests, so the page can never
describe a screenshot that was not actually rendered.
"""
import html, json, pathlib, datetime

root = pathlib.Path(__file__).resolve().parent.parent
d = root / "docs" / "screens"
items = json.loads((d / "manifest.json").read_text())

def esc(s): return html.escape(s or "")

groups = {}
for it in items:
    groups.setdefault(it["path"], []).append(it)

FLAGS = ("THE KEY", "THE USER", "NEW SCREEN")
flagged = sum(1 for i in items if i["lookAt"].startswith(FLAGS))

body = []
for path, entries in groups.items():
    body.append(f'<h2 class="path">{esc(path)}</h2>')
    for e in entries:
        is_flag = e["lookAt"].startswith(FLAGS)
        look = esc(e["lookAt"])
        if is_flag:
            head, _, rest = look.partition(":")
            look = f'<em class="callout">{head}:</em>{rest}' if rest else look
        body.append(f"""<section class="card{' flagged' if is_flag else ''}" id="{esc(e['id'])}">
  <a class="shot" href="{esc(e['file'])}"><img src="{esc(e['file'])}" alt="{esc(e['title'])}" width="{esc(e['width'])}" height="{esc(e['height'])}" loading="lazy"></a>
  <div class="notes">
    <p class="meta"><span class="sid">{esc(e['id'])}</span><code>{esc(e['step'])}</code></p>
    <h3>{esc(e['title'])}</h3>
    <p class="purpose">{esc(e['purpose'])}</p>
    <p class="field"><span class="k">Look at</span>{look}</p>
    <p class="field"><span class="k">On screen for</span>{esc(e['dwell'])}</p>
  </div>
</section>""")

page = f"""<title>Changeover Screens</title>
<style>
  :root {{
    --ground:#f6f6f8; --panel:#ffffff; --ink:#1b1b1f; --mut:#6a6a74;
    --line:#e3e3e8; --flag:#9a4a05; --flag-bg:#fdf5ec; --flag-line:#e8c79d;
    --code:#55555f;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      color-scheme: dark;
      --ground:#121215; --panel:#1a1a1f; --ink:#ececf0; --mut:#9898a3;
      --line:#2a2a31; --flag:#f0a44a; --flag-bg:#241a10; --flag-line:#4a3822;
      --code:#a0a0ab;
    }}
  }}
  :root[data-theme="dark"] {{
    color-scheme: dark;
    --ground:#121215; --panel:#1a1a1f; --ink:#ececf0; --mut:#9898a3;
    --line:#2a2a31; --flag:#f0a44a; --flag-bg:#241a10; --flag-line:#4a3822;
    --code:#a0a0ab;
  }}
  body {{
    background: var(--ground); color: var(--ink); margin:0;
    font: 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  }}
  .wrap {{ max-width: 1120px; margin: 0 auto; padding-inline: 16px; padding-block: 40px 88px; }}
  h1 {{ font-size: clamp(24px, 4vw, 32px); letter-spacing: -.021em; margin: 0 0 10px; text-wrap: balance; }}
  .lede {{ color: var(--mut); max-width: 64ch; margin: 0 0 8px; }}
  .how {{ color: var(--mut); font-size: 13px; max-width: 64ch; margin: 0; }}
  .how code {{ font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--code); }}
  .counts {{ display:flex; gap:22px; flex-wrap:wrap; margin: 22px 0 0; padding:0; list-style:none; }}
  .counts div {{ font-variant-numeric: tabular-nums; }}
  .counts b {{ display:block; font-size:22px; letter-spacing:-.02em; }}
  .counts span {{ font-size:11px; text-transform:uppercase; letter-spacing:.07em; color:var(--mut); }}
  h2.path {{
    font-size: 11.5px; text-transform: uppercase; letter-spacing: .09em; color: var(--mut);
    margin: 46px 0 14px; padding-bottom: 9px; border-bottom: 1px solid var(--line);
  }}
  .card {{
    display: grid; grid-template-columns: minmax(0, 620px) minmax(240px, 1fr);
    gap: 26px; align-items: start; padding: 18px; margin-bottom: 18px;
    background: var(--panel); border: 1px solid var(--line); border-radius: 12px;
  }}
  .card.flagged {{ background: var(--flag-bg); border-color: var(--flag-line); }}
  .shot {{ display:block; }}
  .shot img {{ width: 100%; height: auto; max-width: 100%; display: block;
               border: 1px solid var(--line); border-radius: 7px; }}
  .meta {{ display:flex; gap:10px; align-items:baseline; flex-wrap:wrap; margin:0 0 6px; }}
  .sid, .meta code {{ font: 11.5px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--mut); }}
  .meta code {{ color: var(--code); }}
  h3 {{ margin: 0 0 9px; font-size: 16.5px; letter-spacing: -.01em; text-wrap: balance; }}
  .purpose {{ margin: 0 0 14px; }}
  .field {{ margin: 0 0 12px; font-size: 13.5px; color: var(--mut); }}
  .field .k {{ display:block; font-size: 10.5px; text-transform: uppercase;
               letter-spacing: .07em; color: var(--ink); margin-bottom: 3px; }}
  .card.flagged .field .k {{ color: var(--flag); }}
  .callout {{ font-style: normal; font-weight: 600; color: var(--flag); }}
  footer {{ margin-top: 52px; padding-top: 18px; border-top: 1px solid var(--line);
            color: var(--mut); font-size: 13px; max-width: 72ch; }}
  footer code {{ font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--code); }}
  a {{ color: inherit; }}
  a:focus-visible, .shot:focus-visible {{ outline: 2px solid var(--flag); outline-offset: 3px; }}
  @media (max-width: 820px) {{ .card {{ grid-template-columns: 1fr; }} }}
</style>

<div class="wrap">
  <h1>Every screen the rip window can show</h1>
  <p class="lede">Rendered from the app's real views driven by real controller state, so each
     picture is a screen the app can actually reach. Highlighted cards carry an open design
     question. Click any image for full size.</p>
  <p class="how">Regenerate with
     <code>./run-remote-tests.sh gordon ScreenshotHarnessTests/everyScreenRendersToAPNG</code>,
     then <code>Tools/build-screen-review.py</code>.</p>
  <ul class="counts">
    <div><b>{len(items)}</b><span>screens</span></div>
    <div><b>{len(groups)}</b><span>paths</span></div>
    <div><b>{flagged}</b><span>open questions</span></div>
    <div><b>{datetime.date.today().isoformat()}</b><span>generated</span></div>
  </ul>
  {''.join(body)}
  <footer>Every scenario asserts the <code>FlowStep</code> it derived, so a screenshot cannot drift
    from the state it claims. Captured off-screen via <code>NSHostingView.cacheDisplay</code> —
    no UI tests, no VM, no window server, nothing automated against a live app.</footer>
</div>"""

(d / "index.html").write_text(page)
print(f"wrote {d/'index.html'} — {len(items)} screens, {flagged} flagged")
