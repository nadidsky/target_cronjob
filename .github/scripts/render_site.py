"""Render the project's source files as a syntax-highlighted static site.

Produces a `site/` tree with:
  - index.html               : landing page with cards per implementation
  - pygments.css             : shared highlighter stylesheet
  - view/<slug>.html         : one page per source file

All pages share the same dark template. No external CDN; everything is inlined
or sits next to the HTML.
"""

from __future__ import annotations

import html
from dataclasses import dataclass
from pathlib import Path

from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "site"
VIEW = SITE / "view"


@dataclass(frozen=True)
class Source:
    path: Path
    title: str
    lang: str
    group: str


SOURCES = [
    Source(ROOT / "src/posix_sh/target_job.sh", "target_job.sh", "bash", "POSIX sh"),
    Source(ROOT / "src/posix_sh/target.conf",   "target.conf",   "bash", "POSIX sh"),
    Source(ROOT / "src/bash/target_job.sh",     "target_job.sh", "bash", "bash"),
    Source(ROOT / "src/bash/target.conf",       "target.conf",   "bash", "bash"),
    Source(ROOT / "src/go/target_job.go",       "target_job.go", "go",   "Go"),
    Source(ROOT / "src/go/config.json",         "config.json",   "json", "Go"),
]

GROUP_META = {
    "POSIX sh": {
        "tagline": "Runs on anything with /bin/sh — dash, ash, busybox, Solaris, HP-UX, AIX.",
        "accent": "#8ab4f8",
        "deps": "expr · cut · awk · tail · mkdir",
    },
    "bash": {
        "tagline": "bash 3.2+ with GNU coreutils and flock. The shortest implementation.",
        "accent": "#a8d8a8",
        "deps": "bash · date -d · flock",
    },
    "Go": {
        "tagline": "Single-binary, stdlib-only. Cross-compiled for Linux and Windows.",
        "accent": "#f5c06b",
        "deps": "go · no third-party deps",
    },
}

PAGE_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<link rel="stylesheet" href="{root}pygments.css">
<style>
  :root {{
    --bg: #0d1117;
    --bg-elev: #161b22;
    --border: #30363d;
    --fg: #e6edf3;
    --fg-muted: #8b949e;
    --accent: #58a6ff;
    --accent-2: #a8d8a8;
    --accent-3: #f5c06b;
    --radius: 10px;
  }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; padding: 0; background: var(--bg); color: var(--fg); }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, system-ui, sans-serif;
    line-height: 1.55;
    font-size: 15px;
  }}
  a {{ color: var(--accent); text-decoration: none; }}
  a:hover {{ text-decoration: underline; }}
  code, pre {{
    font-family: "SF Mono", "JetBrains Mono", "Fira Code", Menlo, Consolas, monospace;
    font-size: 13.5px;
  }}
  header.site {{
    border-bottom: 1px solid var(--border);
    padding: 24px 32px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    flex-wrap: wrap;
  }}
  header.site h1 {{
    margin: 0;
    font-size: 20px;
    letter-spacing: -0.01em;
  }}
  header.site h1 a {{ color: var(--fg); }}
  header.site .sub {{ color: var(--fg-muted); font-size: 14px; }}
  main {{ max-width: 1120px; margin: 0 auto; padding: 32px; }}
  .hero {{ margin-bottom: 40px; }}
  .hero h2 {{
    font-size: 30px;
    margin: 0 0 12px 0;
    letter-spacing: -0.02em;
    line-height: 1.2;
  }}
  .hero p {{ color: var(--fg-muted); max-width: 62ch; margin: 0; }}
  .grid {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
    gap: 20px;
  }}
  .card {{
    background: var(--bg-elev);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 20px 22px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    transition: border-color 0.15s ease, transform 0.15s ease;
  }}
  .card:hover {{ border-color: var(--accent); transform: translateY(-2px); }}
  .card h3 {{
    margin: 0;
    font-size: 17px;
    display: flex;
    align-items: center;
    gap: 10px;
  }}
  .card h3 .dot {{
    width: 10px;
    height: 10px;
    border-radius: 50%;
    display: inline-block;
  }}
  .card .tagline {{ color: var(--fg-muted); font-size: 13.5px; margin: 0; }}
  .card .deps {{
    color: var(--fg-muted);
    font-size: 12px;
    padding-top: 8px;
    border-top: 1px dashed var(--border);
  }}
  .card ul {{ list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 6px; }}
  .card li a {{
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 6px 10px;
    border-radius: 6px;
    background: rgba(255,255,255,0.02);
  }}
  .card li a:hover {{ background: rgba(88,166,255,0.08); text-decoration: none; }}
  .card li .filename {{ font-family: inherit; }}
  .card li .lang {{ font-size: 11px; color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.08em; }}
  footer.site {{
    border-top: 1px solid var(--border);
    padding: 24px 32px;
    color: var(--fg-muted);
    font-size: 13px;
    text-align: center;
  }}
  /* ---- source view ---- */
  .view-header {{
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin-bottom: 16px;
    gap: 16px;
    flex-wrap: wrap;
  }}
  .view-header h2 {{ margin: 0; font-size: 22px; letter-spacing: -0.01em; }}
  .view-header .crumbs {{ color: var(--fg-muted); font-size: 13px; }}
  .source {{
    background: var(--bg-elev);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 0;
    overflow: auto;
    font-size: 13px;
  }}
  .source pre {{ margin: 0; padding: 18px 20px; }}
  .source table {{ border-collapse: collapse; width: 100%; }}
  .source td.linenos {{
    color: var(--fg-muted);
    text-align: right;
    padding: 0 14px 0 16px;
    user-select: none;
    border-right: 1px solid var(--border);
    background: rgba(0,0,0,0.15);
    vertical-align: top;
  }}
  .source td.code {{ padding: 0; width: 100%; vertical-align: top; }}
  .source td.code pre {{ padding: 0 20px; }}
  .source .linenodiv pre {{ padding: 18px 14px 18px 16px; margin: 0; }}
</style>
</head>
<body>
<header class="site">
  <h1><a href="{root}index.html">target_cronjob</a></h1>
  <span class="sub">POSIX sh · bash · Go — same behaviour, three ways</span>
</header>
<main>
{body}
</main>
<footer class="site">
  Rendered from the main branch. View the project on
  <a href="https://github.com/nadidsky/target_cronjob">GitHub</a>.
</footer>
</body>
</html>
"""


def slug_for(src: Source) -> str:
    return (
        str(src.path.relative_to(ROOT))
        .replace("/", "_")
        .replace("\\", "_")
    )


def render_index() -> str:
    groups: dict[str, list[Source]] = {}
    for s in SOURCES:
        groups.setdefault(s.group, []).append(s)

    cards = []
    for group, items in groups.items():
        meta = GROUP_META[group]
        links = "\n".join(
            f'        <li><a href="view/{slug_for(s)}.html">'
            f'<span class="filename">{html.escape(s.title)}</span>'
            f'<span class="lang">{html.escape(s.lang)}</span></a></li>'
            for s in items
        )
        cards.append(
            f"""    <div class="card">
      <h3><span class="dot" style="background: {meta['accent']}"></span>{html.escape(group)}</h3>
      <p class="tagline">{html.escape(meta['tagline'])}</p>
      <ul>
{links}
      </ul>
      <p class="deps">{html.escape(meta['deps'])}</p>
    </div>"""
        )

    hero = """  <section class="hero">
    <h2>A cron job that never double-processes a day.</h2>
    <p>Every minute, four silent gates: is it past the trigger time, is today a TARGET open day,
       has it already succeeded, is another instance running? Only when all four pass does it run —
       and it runs over every calendar date since the last success, so weekends, holidays, and
       failed days are backfilled automatically.</p>
  </section>
"""
    body = hero + f'  <div class="grid">\n' + "\n".join(cards) + "\n  </div>"
    return PAGE_TEMPLATE.format(title="target_cronjob", root="", body=body)


def render_view(src: Source, formatter: HtmlFormatter) -> str:
    lexer = get_lexer_by_name(src.lang)
    code = src.path.read_text(encoding="utf-8")
    highlighted = highlight(code, lexer, formatter)

    rel = src.path.relative_to(ROOT).as_posix()
    body = f"""  <div class="view-header">
    <h2>{html.escape(src.title)}</h2>
    <span class="crumbs">{html.escape(rel)} · {html.escape(src.group)}</span>
  </div>
  {highlighted}
"""
    return PAGE_TEMPLATE.format(
        title=f"{src.title} — target_cronjob",
        root="../",
        body=body,
    )


def main() -> None:
    SITE.mkdir(exist_ok=True)
    VIEW.mkdir(exist_ok=True)

    formatter = HtmlFormatter(
        style="github-dark",
        cssclass="source",
        linenos="table",
        nobackground=True,
    )
    (SITE / "pygments.css").write_text(
        formatter.get_style_defs(".source"), encoding="utf-8"
    )

    (SITE / "index.html").write_text(render_index(), encoding="utf-8")

    for src in SOURCES:
        if not src.path.exists():
            raise FileNotFoundError(src.path)
        out = VIEW / f"{slug_for(src)}.html"
        out.write_text(render_view(src, formatter), encoding="utf-8")
        print(f"rendered {out.relative_to(ROOT)}")

    (SITE / ".nojekyll").write_text("", encoding="utf-8")

    print(f"\nSite built at {SITE}")


if __name__ == "__main__":
    main()
