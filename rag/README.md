# RAG Nora — scope "public"

Donne à Nora accès à la base de recherche contre-culture (`recherche-documentaire/`
du projet documentaire), avec obligation de citer ses sources et interdiction
d'inventer quand elles ne couvrent pas la question. Scope **public** seulement
(cf. `___RAG_Documentaire_Contre_Culture___/scopes/public.md` sur le NAS) — pas
`reference-only` ni `droits-a-verifier`.

## Fichiers

- `build_index.py` — lit `\\TrueNAS\rag\...\corpus\recherche-documentaire`
  (lecture seule), découpe chaque fiche (entière, ou par section `##` si trop
  longue), embedde via Ollama (`nomic-embed-text`), écrit `index.json`.
- `index.json` — autonome (texte + embeddings baked in) : `server.js` n'a
  jamais besoin du NAS à l'exécution, seulement de ce fichier.
- `retrieve.js` — module Node utilisé par `server.js` : charge l'index,
  embedde la question, renvoie les passages les plus proches (cosinus) +
  formate le contexte avec la consigne de citation.
- `chat_test.ps1` — client de test en ligne de commande, même logique de
  recherche, pour valider la pertinence avant de toucher à la prod.

## ⚠️ Le score cosinus ne filtre pas la pertinence de façon fiable

Testé le 2026-11-04 : `nomic-embed-text` + requêtes courtes en français donne
des scores qui se chevauchent entre questions pertinentes et hors-sujet
(ex. "tarte aux pommes" → 0.718, "SOS Racisme" → 0.743 ; "Minecraft" → 0.638,
"Jeune Garde antifasciste" → 0.913). Impossible de fixer un seuil qui coupe
proprement l'un sans l'autre. `RAG_MIN_SCORE` (0.35 par défaut) ne sert donc
qu'à éliminer le bruit vraiment nul, **pas** à garantir la pertinence.

La vraie garde-fou contre l'invention est dans la consigne envoyée au modèle
(`formatContext()`/`Format-RagContext`) : même quand des extraits sont
retrouvés, Nora doit juger elle-même s'ils couvrent la question et dire non
sinon. **À valider par un vrai test conversationnel** (`chat_test.ps1`), pas
seulement par le score — demander un truc hors-sujet et vérifier qu'elle dit
qu'elle n'a pas ça dans ses sources plutôt que de broder sur les extraits
non pertinents renvoyés.

## Déclenchement : pas à chaque tour, basé sur le sens

Un « bonjour » ne doit ni interroger le RAG ni faire dévier la conversation
vers le documentaire. Comme le score cosinus ne sépare pas sujet/hors-sujet
(ci-dessus), le déclenchement passe par le modèle de chat lui-même : un
appel court (`RAG_TRIGGER_PROMPT`, 3 tokens de sortie max) lui demande OUI/NON
— sur le dernier message *et* l'historique récent (6 derniers tours), pour
capter aussi bien « c'est hors-sujet » que « ça poursuit un sujet déjà
engagé ». Seul un OUI déclenche l'embedding + la recherche ; sinon Nora
répond normalement, sans mention du RAG.

**Piège vu en test (2026-11-04)** : `chat_test.ps1` avait un `-TimeoutSec 5`
sur l'appel trigger. Sur ce poste, le `mistral` 7B Q4 local met souvent plus
de 5s à sortir son premier token (les réponses de chat elles-mêmes prenaient
46-52s — probablement inférence CPU, pas GPU) : le trigger tombait donc en
timeout à chaque tour après le premier et retombait sur NON par défaut, sans
jamais vraiment demander au modèle. Corrigé à 20s dans le script de test (8s
côté `server.js`, qui visera l'API Mistral en prod, nettement plus rapide —
à revalider si ça timeout aussi là-bas). Symptôme pour repérer ce piège :
le `[trigger]` prend exactement le temps du timeout configuré, à chaque
tour sauf le tout premier.

Le premier prompt testé (sans exemples) se trompait sur des cas simples
("Bonjour !" → OUI à tort, un "merci, bonne soirée" après un sujet
contre-culture → OUI à tort). Ajouter des exemples few-shot dans le prompt a
corrigé les 9 cas de test (salutations, small talk, sujet direct,
continuation de sujet, clôture de sujet, hors-sujet technique) — vérifié le
2026-11-04 via Ollama local (`mistral` 7B Q4). Si vous changez `LLM_MODEL`
en prod, revalider ces mêmes cas : un modèle différent peut réagir
différemment au même prompt.

## ⚠️ Invention détectée en test réel (2026-11-04) — corrigé

Question *"Quel est le nom exact du comptable de la Jeune Garde en 2019 ?"* :
le trigger a timeout (voir plus haut), donc **aucun extrait n'a été injecté**
— et Nora a quand même répondu avec un nom précis et une fausse source
("Wikipédia", qui n'est même pas dans le corpus — explicitement exclu par
`recherche-documentaire/README.md`). Invention grave, non détectée par les
tests précédents.

**Cause** : la consigne "n'invente pas, dis que tu n'as pas ça" ne vivait
que dans `formatContext()` (le message injecté *quand* le RAG se
déclenche). Si le trigger échoue ou répond NON, ce message n'est jamais
envoyé — il ne restait que `SYSTEM_PROMPT`, pas assez strict. **Corrigé** :
la règle anti-invention (ne jamais inventer un fait précis, ne jamais citer
une source non reçue ce tour, jamais "Wikipédia") fait maintenant partie du
`SYSTEM_PROMPT` permanent, indépendamment du déclenchement RAG.

Renforcé aussi : même avec des extraits fournis, le modèle peut citer une
fiche réelle tout en ajoutant des détails qui n'y sont pas (vu sur la
réponse reggae/RAR : un groupe et une chanson mentionnés sans être
clairement dans l'extrait retrouvé). La consigne de citation interdit
maintenant explicitement d'ajouter un détail précis absent de l'extrait.

**À revalider** : relancer les mêmes questions et vérifier qu'elle dit
"je n'ai pas cette info précise" au lieu d'inventer.

## ⚠️ Aplatissement des nuances détecté en test réel (2026-11-04) — corrigé

Avec `qwen2.5:3b-instruct`, comparaison topK=1/2/3 sur *"cites-moi des noms
de groupes de musique antifas"* : les noms cités (Parabellum, Sham 69,
Bérurier Noir...) étaient tous réels et bien dans les extraits — pas
d'invention de nom. Mais les fiches sources posent une réserve explicite
sur plusieurs de ces groupes (ex. *"rien ne permet de présenter [Parabellum]
comme une chanson spécifiquement... antifasciste"*, *"Sham 69... sont relus
depuis 2010 comme les antécédents d'un patrimoine antifasciste"* — donc une
relecture rétrospective, pas un fait établi). Nora a aplati cette réserve en
affirmant simplement "groupes de musique antifascistes", à tous les topK
testés. Ce n'est pas une invention de fait, mais ça revient au même risque :
présenter comme établi ce que la source présente explicitement comme
incertain ou contesté.

**Atténué, pas garanti** : la consigne de citation (`formatContext()`/
`Format-RagContext`) interdit maintenant explicitement de transformer une
réserve ou une nuance de l'extrait en certitude. Revalidé le 2026-11-04 sur
`qwen2.5:3b-instruct` (même question, topK=2 puis 3) : à topK=2 la réserve
est bien restituée ("canonisés... depuis 2010") ; à topK=3 la réponse
retombe sur l'affirmation plate ("groupes de musique antifas"). Même limite
que le déclenchement RAG (cf. plus haut) : un modèle 3B suit la consigne la
plupart du temps, pas systématiquement. Pas de seuil topK qui corrige ça de
façon fiable — à surveiller en test, pas à considérer comme résolu.

## ⚠️ qwen2.5:3b-instruct jugé non fiable pour ce usage (2026-11-04)

Dans un même test court (5 échanges), trois défaillances distinctes, toutes
avec le fix de continuité déjà en place :

1. **Déclencheur qui rate un mot-clé explicite** : *"peux-tu me donner le
   sens des deux acronymes RASH ou SHARP ?"* → NON, alors que "SHARP" est
   un exemple few-shot du prompt déclencheur lui-même. Pas un problème de
   contexte perdu — le mot-clé exact était présent.
2. **Contradiction d'un extrait reçu** : le RAG a retrouvé `groupes/README.md#1`
   (qui documente le groupe français Brigada Flores Magon), et Nora a
   répondu qu'un tel groupe n'existe pas en France — elle n'a pas inventé
   par absence de source, elle a nié ce que la source donnée disait.
3. **Citation fabriquée** : cite "ma fiche sur l'AFA-PB", absente des
   extraits reçus ce tour-là.

**Conclusion** : ce ne sont pas des trous dans le prompt ou l'architecture
(le fix de continuité, lui, est vérifié et fonctionne isolément — voir plus
haut), mais une limite de fiabilité du modèle 3B lui-même. Ne pas utiliser
`qwen2.5:3b-instruct` comme référence pour valider la rigueur anti-invention
ou la logique de citation — seulement pour des tests ponctuels rapides.
`mistral` (7B, plus lent mais plus fiable dans ces tests) reste la
référence locale pour ça. La prod (Mistral cloud) n'utilise ni l'un ni
l'autre.

## Comportement de citation

Nora doit : nommer la fiche (et la section) quand elle s'appuie sur un
extrait ; dire qu'elle n'a pas l'info si les extraits ne couvrent pas la
question (pas d'invention) ; présenter ses propres interprétations comme
telles, distinctes de ce qui vient des documents. Ça vit dans `SYSTEM_PROMPT`
(règle générale) + le contexte injecté par `formatContext()`/`Format-RagContext`
(règle + extraits, par tour).

## Reconstruire l'index

```
cd lipsync/web/rag
"C:\ProgramData\miniconda3\python.exe" -I build_index.py
```

À refaire après toute mise à jour de `recherche-documentaire/` côté source
(`E:\___Documentaire_Contre_Culture___`, jamais modifié directement par ce
script — il faut d'abord resynchroniser `corpus/` sur le NAS, cf. le README
à la racine du dossier NAS).

## Déploiement VPS — tunnel Nginx Proxy Manager

`OLLAMA_URL=http://192.168.1.82:11434` (IP LAN) n'est joignable que depuis
le réseau perso — le VPS (Coolify) ne peut pas l'atteindre directement.
Solution retenue : un sous-domaine `ollama.paulwoisard.fr` exposé via le
NPM maison, HTTPS + Basic Auth.

**Important (souligné par Paul)** : exposer Ollama ne rend pas le RAG lui-même
accessible depuis l'extérieur — seul l'embedding de la question utilisateur
passe par ce tunnel à l'exécution. Le calcul de similarité (comparaison aux
363 vecteurs) tourne **dans le process Node de `server.js`**, en mémoire,
à partir d'`index.json` qui est **copié dans l'image Docker** au build (cf.
`Dockerfile`, `COPY rag ./rag`) — il n'est donc jamais lu depuis le NAS à
l'exécution, ni sur le poste local ni sur le VPS.

### Config Nginx Proxy Manager

**Proxy Host** :
- Domain Names : `ollama.paulwoisard.fr`
- Scheme : `http` (Ollama n'a pas de TLS natif — NPM termine le HTTPS)
- Forward Hostname/IP : `192.168.1.82` (le TrueNAS, qui héberge aussi Ollama)
- Forward Port : `11434`
- Block Common Exploits : activé
- Websockets Support : pas nécessaire

**SSL** (onglet du même Proxy Host) :
- Request a new SSL Certificate (Let's Encrypt)
- Force SSL : activé
- HTTP/2 Support : activé

**Access List** (Security → Access Lists → Add) :
- Authorization : Basic Auth, user `nora` + mot de passe généré (voir
  `.env` local — jamais commité, à reporter dans les variables d'env Coolify
  comme `OLLAMA_AUTH_USER`/`OLLAMA_AUTH_PASS`)
- Attacher cette Access List au Proxy Host `ollama.paulwoisard.fr` (dropdown
  "Access List" dans l'édition du Proxy Host)

### Vérification

Depuis une machine hors LAN (ou juste en forçant le DNS public) :
```bash
curl -u nora:<mot-de-passe> -X POST https://ollama.paulwoisard.fr/api/embeddings \
  -d '{"model":"nomic-embed-text","prompt":"test"}'
```
Doit renvoyer un vecteur. Sans `-u`, doit renvoyer 401.

Tant que ce n'est pas vérifié, laisser `OLLAMA_URL` vide dans l'env Coolify :
le RAG se désactive proprement (`retrieve()` renvoie `[]`), Nora répond sans
extraits mais garde quand même la consigne "ne pas inventer de faits précis
sans source".

**Aucun push ni déploiement Coolify tant que Paul n'a pas validé** —
validation en cours en local uniquement (`chat_test.ps1`).
