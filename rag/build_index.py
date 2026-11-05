"""Construit l'index RAG "public" de Nora.

Source : \\TrueNAS\\rag\\___RAG_Documentaire_Contre_Culture___\\corpus\\recherche-documentaire
(scope public uniquement — cf. scopes/public.md sur le NAS). Ne touche jamais
la source : lecture seule.

Sortie : index.json, autonome (texte + embeddings baked in), pour que
server.js (conteneur Docker, VPS) n'ait pas besoin d'accéder au NAS.

Usage : python -I build_index.py
Pré-requis : Ollama accessible (OLLAMA_URL), modèle d'embedding tiré
(nomic-embed-text).
"""
import json
import os
import re
import sys
import urllib.request

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://192.168.1.82:11434")
EMBED_MODEL = "nomic-embed-text"
CORPUS_DIR = r"\\TrueNAS\rag\___RAG_Documentaire_Contre_Culture___\corpus\recherche-documentaire"
OUT_PATH = os.path.join(os.path.dirname(__file__), "index.json")

MAX_CHARS_PER_CHUNK = 3000


def embed(text):
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/embeddings",
        data=json.dumps({
            "model": EMBED_MODEL,
            "prompt": text,
            "options": {"num_ctx": 8192},
        }).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read())["embedding"]
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"HTTPError {e.code}: {body}", file=sys.stderr)
        raise


def pack_paragraphs(text, limit):
    """Regroupe des paragraphes (séparés par ligne vide) en blocs <= limit."""
    paras = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    chunks, current = [], ""
    for p in paras:
        if len(p) > limit:
            # paragraphe isolé trop long (ex: table) -> découpe brute
            if current:
                chunks.append(current)
                current = ""
            for i in range(0, len(p), limit):
                chunks.append(p[i:i + limit])
            continue
        candidate = f"{current}\n\n{p}" if current else p
        if len(candidate) > limit:
            chunks.append(current)
            current = p
        else:
            current = candidate
    if current:
        chunks.append(current)
    return chunks


def split_sections(text):
    """## -> si une section dépasse encore la limite, repasse par paragraphes."""
    if len(text) <= MAX_CHARS_PER_CHUNK:
        return [text]
    parts = re.split(r"(?=^## )", text, flags=re.MULTILINE)
    parts = [p.strip() for p in parts if p.strip()]
    if not parts:
        parts = [text]

    final = []
    for p in parts:
        if len(p) <= MAX_CHARS_PER_CHUNK:
            final.append(p)
        else:
            final.extend(pack_paragraphs(p, MAX_CHARS_PER_CHUNK))
    return final


def main():
    entries = []
    for root, _dirs, files in os.walk(CORPUS_DIR):
        for fname in sorted(files):
            if not fname.endswith(".md"):
                continue
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, CORPUS_DIR).replace("\\", "/")
            with open(fpath, "r", encoding="utf-8") as f:
                text = f.read().strip()
            if not text:
                continue
            title_match = re.search(r"^#\s+(.+)$", text, flags=re.MULTILINE)
            title = title_match.group(1).strip() if title_match else rel

            chunks = split_sections(text)
            for i, chunk in enumerate(chunks):
                entry_id = rel if len(chunks) == 1 else f"{rel}#{i}"
                section_match = re.match(r"^##\s+(.+)$", chunk, flags=re.MULTILINE)
                section = section_match.group(1).strip() if section_match else None
                print(f"embedding {entry_id} ({len(chunk)} chars)...", file=sys.stderr)
                vec = embed(chunk)
                entries.append({
                    "id": entry_id,
                    "source": rel,
                    "title": title,
                    "section": section,
                    "text": chunk,
                    "embedding": vec,
                })

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump({
            "model": EMBED_MODEL,
            "scope": "public",
            "count": len(entries),
            "entries": entries,
        }, f, ensure_ascii=False)

    print(f"OK: {len(entries)} chunks -> {OUT_PATH}", file=sys.stderr)


if __name__ == "__main__":
    main()
