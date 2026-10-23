"""Builds the public privacy and account-deletion pages (docs/play-store/site/)
from the newest privacy policy in supabase/seed/trinity_energie.sql, so the
web page and the text accepted in the app are the same words.
Run: python3 docs/play-store/build_site.py"""
import re, html, pathlib

root = pathlib.Path(__file__).resolve().parents[2]
seed = (root / "supabase/seed/trinity_energie.sql").read_text()
found = re.findall(r"values \('confidentialite', '([^']+)', '([^']+)', '(.*?)', '', false\)", seed, re.S)
version, title, body = max(found, key=lambda f: f[0])
body = body.replace("''", "'")

def inline(t):
    return re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", html.escape(t))

out, para, items, table = [], [], [], []
def flush():
    global para, items, table
    if para: out.append("<p>" + inline(" ".join(para)) + "</p>"); para = []
    if items: out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>"); items = []
    if table:
        rows = [[c.strip() for c in r.strip("|").split("|")] for r in table if not re.match(r"^\|[-\s|]+\|$", r)]
        head = "".join(f"<th>{inline(c)}</th>" for c in rows[0])
        rest = "".join("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in rows[1:])
        out.append(f"<table><thead><tr>{head}</tr></thead><tbody>{rest}</tbody></table>"); table = []
for line in body.split("\n"):
    s = line.rstrip()
    if s.startswith("## "): flush(); out.append("<h2>" + inline(s[3:]) + "</h2>")
    elif s.startswith("|"):
        if para or items: flush()
        table.append(s)
    elif s.startswith("- "):
        if para or table: flush()
        items.append(s[2:])
    elif s.startswith("  ") and items: items[-1] += " " + s.strip()
    elif not s.strip(): flush()
    else:
        if table or items: flush()
        para.append(s.strip())
flush()

CSS = """:root{--bg:#03081A;--ink:#F5F7FC;--muted:rgba(220,229,247,.68);--blue:#4F95FF;--line:rgba(255,255,255,.12)}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.6 Manrope,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
main{max-width:760px;margin:0 auto;padding:40px 20px 64px}.brand{letter-spacing:.22em;font-weight:600;font-size:14px}
h1{font-family:Sora,-apple-system,sans-serif;font-size:34px;line-height:1.2;margin:28px 0 6px}.meta{color:var(--muted);font-size:14px;margin:0 0 28px}
h2{font-family:Sora,-apple-system,sans-serif;font-size:21px;margin:32px 0 8px}p,li{color:var(--muted)}strong{color:var(--ink)}a{color:var(--blue)}
table{border-collapse:collapse;width:100%;margin:8px 0;font-size:15px}td,th{border-bottom:1px solid var(--line);padding:10px 8px;text-align:left;vertical-align:top}th{color:var(--ink)}td{color:var(--muted)}
.card{border:1px solid var(--line);border-radius:18px;padding:18px 20px;background:rgba(255,255,255,.04);margin:16px 0}"""

def page(t, inner, desc):
    return (f'<!doctype html>\n<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\n'
            f'<title>{html.escape(t)} — Trinity Énergie</title><meta name="description" content="{html.escape(desc)}">\n'
            f'<style>{CSS}</style></head><body><main>\n<div class="brand">△ TRINITY ÉNERGIE</div>\n{inner}\n</main></body></html>\n')

site = root / "docs/play-store/site"; site.mkdir(parents=True, exist_ok=True)
(site / "confidentialite.html").write_text(page(title,
    f"<h1>{html.escape(title)}</h1><p class='meta'>Application Trinity Énergie (iPhone et Android) · version {html.escape(version)}</p>\n" + "\n".join(out),
    "Politique de confidentialité de l'application Trinity Énergie."))
(site / "suppression-compte.html").write_text(page("Supprimer votre compte", """<h1>Supprimer votre compte</h1>
<p class="meta">Application Trinity Énergie (iPhone et Android) · TRINITY ENERGIE, SAS, 945 rue du Général de Gaulle, 59310 Aix-en-Pévèle</p>
<h2>Depuis l'application</h2>
<div class="card"><p>Ouvrez l'application, puis <strong>Profil → Supprimer mon compte</strong>, et confirmez. Votre accès est fermé immédiatement.</p></div>
<h2>Sans l'application</h2>
<div class="card"><p>Écrivez à <a href="mailto:pierrelouis@trinity-energie.fr?subject=Suppression%20de%20mon%20compte">pierrelouis@trinity-energie.fr</a> depuis l'adresse de votre compte, avec pour objet « Suppression de mon compte ». La demande est traitée sous un mois au plus.</p></div>
<h2>Ce qui est supprimé, ce qui est conservé</h2>
<p>Les données personnelles de votre compte (nom, coordonnées, téléphone, documents, messages) sont effacées.</p>
<p>Les factures et les recommandations qui s'y rattachent sont conservées <strong>10 ans</strong>, au titre des obligations comptables (article L123-22 du Code de commerce), sans autre usage.</p>
<p>Voir aussi la <a href="confidentialite.html">politique de confidentialité</a>.</p>""",
    "Comment supprimer votre compte Trinity Énergie et vos données."))
(site / "index.html").write_text(page("Application", """<h1>Trinity Énergie</h1><p class="meta">L'espace des apporteurs d'affaires</p>
<p><a href="confidentialite.html">Politique de confidentialité</a></p><p><a href="suppression-compte.html">Supprimer votre compte</a></p>""",
    "Trinity Énergie, l'application des apporteurs d'affaires."))
print("built from", version)
