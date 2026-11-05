// Recherche RAG (scope "public") : charge index.json une fois, embedde la
// requête via Ollama, renvoie les passages les plus proches par similarité
// cosinus. index.json est auto-suffisant (texte + embeddings déjà calculés
// par build_index.py) — ce module n'a jamais besoin du NAS à l'exécution.
import { readFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const INDEX_PATH = join(__dirname, "index.json");

let indexPromise = null;
function loadIndex() {
  if (!indexPromise) {
    indexPromise = readFile(INDEX_PATH, "utf8")
      .then(raw => JSON.parse(raw))
      .catch(err => {
        indexPromise = null; // permet de réessayer si le fichier arrive après coup
        throw err;
      });
  }
  return indexPromise;
}

function cosine(a, b) {
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (Math.sqrt(na) * Math.sqrt(nb) || 1);
}

export async function embedQuery(text, { ollamaUrl, model, authUser, authPass }) {
  const headers = { "content-type": "application/json" };
  if (authUser) {
    headers.authorization = `Basic ${Buffer.from(`${authUser}:${authPass}`).toString("base64")}`;
  }
  const res = await fetch(`${ollamaUrl}/api/embeddings`, {
    method: "POST",
    headers,
    body: JSON.stringify({ model, prompt: text, options: { num_ctx: 8192 } }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw new Error(`embeddings ${res.status}: ${await res.text()}`);
  const data = await res.json();
  return data.embedding;
}

// Retourne [] en cas d'échec (index absent, Ollama injoignable, etc.) plutôt
// que de faire planter la conversation : le RAG est une amélioration, jamais
// un point de blocage du chat.
//
// `history` (le tour précédent) est collé à `query` avant l'embedding : sans
// ça, une relance qui ne renomme pas le sujet (ex. "le sens des deux
// acronymes" après avoir parlé de RASH/SHARP) peut rater la fiche pourtant
// trouvée au tour juste avant — vu en test réel, cf. rag/README.md. Pas
// d'appel LLM pour ça, juste du texte en plus avant l'embedding.
export async function retrieve(query, { ollamaUrl, embedModel, authUser, authPass, topK = 3, minScore = 0.5, history = [] } = {}) {
  if (!ollamaUrl) return [];
  try {
    const recent = history.slice(-2).map(m => m.content).join(" ");
    const searchText = recent ? `${recent} ${query}` : query;
    const [index, queryVec] = await Promise.all([
      loadIndex(),
      embedQuery(searchText, { ollamaUrl, model: embedModel, authUser, authPass }),
    ]);
    return index.entries
      .map(e => ({ ...e, score: cosine(e.embedding, queryVec) }))
      .filter(e => e.score >= minScore)
      .sort((a, b) => b.score - a.score)
      .slice(0, topK)
      .map(({ embedding, ...rest }) => rest); // ne pas trimballer les vecteurs plus loin
  } catch (err) {
    console.warn("[rag] retrieve failed:", err.message || err);
    return [];
  }
}

function citationLabel(h) {
  return h.section ? `${h.title} — ${h.section}` : h.title;
}

// Avec hits : les extraits + la règle de citation (quelle fiche/section nommer).
// Sans hits : l'interdiction d'inventer sur ce tour précis, pour ne pas réduire
// Nora au silence sur tout sujet hors RAG (elle peut encore donner son avis).
export function formatContext(hits) {
  if (!hits.length) {
    return "Aucun document retrouvé dans ta base de recherche pour cette question. N'invente aucun fait précis (dates, noms, citations) sur les contre-cultures : dis que tu n'as pas ça dans tes sources. Tu peux donner ton avis ou une piste, mais présente-le clairement comme ton interprétation, pas comme un fait documenté.";
  }
  const blocks = hits
    .map(h => `Fiche : ${citationLabel(h)}\n${h.text}`)
    .join("\n\n---\n\n");
  return [
    "Extraits de ta base de recherche sur les contre-cultures, trouvés pour cette question :",
    blocks,
    "Règle : quand tu t'appuies sur un extrait ci-dessus, dis d'où ça vient (nomme la fiche, ex. \"d'après ma fiche sur l'AFA-PB...\"). Reformule avec tes mots, ne recopie pas le texte tel quel, et n'ajoute aucun détail précis (nom, date, groupe, chiffre, titre) qui n'est pas dans l'extrait, même s'il te semble plausible. Si ces extraits ne couvrent pas vraiment la question posée, dis-le au lieu d'inventer. Si l'extrait exprime une réserve, une nuance ou un doute (ex. \"rien ne permet de dire que...\", \"relu depuis comme...\", \"ne pas assimiler à...\"), restitue cette réserve dans ta réponse au lieu de la transformer en certitude. Toute interprétation ou idée qui vient de toi et pas des extraits doit être présentée comme ton avis.",
  ].join("\n\n");
}
