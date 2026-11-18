"""Build guide-simple.uk.pdf from guide-simple.uk.md.

    python3 make_pdf.py

The Markdown file is the source; the PDF is never edited by hand. The page is laid out as
HTML and printed by Chrome, so the text in the PDF stays selectable and the prompt can be
copied out of it. After printing, the script reads the PDF back and checks that every line
of the prompt is in it, when pypdf or PyMuPDF is installed.
"""
import html
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent
SOURCE = ROOT / "guide-simple.uk.md"
TARGET = ROOT / "guide-simple.uk.pdf"
CHROME = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    "/usr/bin/google-chrome",
]

CSS = """
:root { --purple: #6B46C1; --purple-pale: #EDE9FE; --ink: #1A1A2E; --muted: #5C5C7A; }
@page { size: A4 portrait; margin: 14mm 15mm 12mm 15mm; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; color: var(--ink); background: #fff;
  font-family: Inter, "Segoe UI", Arial, sans-serif;
  -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { font-size: 11pt; line-height: 1.4; }
.brand { display: flex; align-items: baseline; justify-content: space-between;
  border-bottom: 1.5px solid var(--purple); padding-bottom: 5px; }
.brand__name { font-size: 9pt; font-weight: 700; letter-spacing: 0.16em;
  text-transform: uppercase; color: var(--purple); }
.brand__note { font-size: 8.2pt; color: var(--muted); }
h1 { font-size: 21pt; font-weight: 700; line-height: 1.15; margin: 12px 0 6px;
  letter-spacing: -0.015em; }
p { margin: 0 0 8px; }
.lead { color: var(--muted); font-size: 10.2pt; }
.step { display: flex; align-items: center; gap: 9px; margin: 14px 0 6px; }
.step__num { width: 20px; height: 20px; flex: 0 0 20px; border-radius: 50%;
  background: var(--purple); color: #fff; font-size: 10pt; font-weight: 700;
  display: flex; align-items: center; justify-content: center; }
.step__title { font-size: 13pt; font-weight: 700; }
a { color: var(--purple); font-weight: 600; text-decoration: none; }
pre { margin: 6px 0 10px; padding: 10px 12px; background: var(--purple-pale);
  border-left: 3px solid var(--purple); border-radius: 3px;
  font-family: Menlo, Consolas, "Courier New", monospace; font-size: 8.3pt;
  line-height: 1.42; white-space: pre-wrap; overflow-wrap: anywhere; }
"""


def blocks(text):
    """Split the small Markdown subset the guide uses into (kind, content) pairs."""
    out, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("```"):
            j = i + 1
            while not lines[j].startswith("```"):
                j += 1
            out.append(("code", "\n".join(lines[i + 1:j])))
            i = j + 1
        elif line.startswith("## "):
            out.append(("h2", line[3:]))
            i += 1
        elif line.startswith("# "):
            out.append(("h1", line[2:]))
            i += 1
        elif line.strip():
            out.append(("p", line.strip()))
            i += 1
        else:
            i += 1
    return out


def render(parts):
    body, seen_h1 = [], False
    for kind, content in parts:
        text = html.escape(content)
        if kind == "h1":
            body.append(f"<h1>{text}</h1>")
            seen_h1 = True
        elif kind == "h2":
            num, _, title = content.partition(". ")
            body.append(f'<div class="step"><span class="step__num">{html.escape(num)}</span>'
                        f'<span class="step__title">{html.escape(title)}</span></div>')
        elif kind == "code":
            body.append(f"<pre>{text}</pre>")
        elif re.fullmatch(r"https://\S+", content):
            body.append(f'<p><a href="{text}">{text}</a></p>')
        else:
            cls = ' class="lead"' if seen_h1 and not any(b.startswith('<div class="step"') for b in body) else ""
            body.append(f"<p{cls}>{text}</p>")
    title = html.escape(next(c for k, c in parts if k == "h1"))
    return (f'<!DOCTYPE html>\n<html lang="uk">\n<head>\n<meta charset="utf-8">\n<title>{title}</title>\n'
            f"<style>{CSS}</style>\n</head>\n<body>\n"
            '<div class="brand"><span class="brand__name">A&amp;I Mastery</span>'
            '<span class="brand__note">ai-mastery.xyz</span></div>\n'
            + "\n".join(body) + "\n</body>\n</html>\n")


def pdf_text(path):
    try:
        import fitz  # PyMuPDF
        with fitz.open(path) as doc:
            return len(doc), "\n".join(page.get_text() for page in doc)
    except ImportError:
        pass
    try:
        from pypdf import PdfReader
        reader = PdfReader(str(path))
        return len(reader.pages), "\n".join(page.extract_text() for page in reader.pages)
    except ImportError:
        return None, None


def squeeze(text):
    return re.sub(r"\s+", "", text)


def main():
    parts = blocks(SOURCE.read_text(encoding="utf-8"))
    chrome = next((c for c in CHROME if pathlib.Path(c).exists()), None)
    if chrome is None:
        sys.exit("Chrome was not found; it prints the page.")
    with tempfile.TemporaryDirectory() as tmp:
        page = pathlib.Path(tmp) / "guide.html"
        page.write_text(render(parts), encoding="utf-8")
        subprocess.run([chrome, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                        f"--user-data-dir={pathlib.Path(tmp) / 'profile'}",
                        f"--print-to-pdf={TARGET}", page.as_uri()],
                       check=True, timeout=120, capture_output=True)
    pages, text = pdf_text(TARGET)
    if text is None:
        print(f"wrote {TARGET.name}; install pypdf or PyMuPDF to have the text checked")
        return
    prompt = next(c for k, c in parts if k == "code")
    missing = [line for line in prompt.split("\n") if line.strip() and squeeze(line) not in squeeze(text)]
    if missing:
        sys.exit(f"{TARGET.name}: {len(missing)} line(s) of the prompt are not in the PDF text, first: {missing[0]!r}")
    print(f"wrote {TARGET.name}: {pages} page(s); every line of the prompt can be copied out of it")


if __name__ == "__main__":
    main()
