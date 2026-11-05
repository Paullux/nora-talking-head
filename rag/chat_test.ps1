# Chat de test avec Nora + RAG (scope "public") via Ollama local.
# Reprend le script de test existant, ajoute une recherche RAG avant chaque
# tour : embedding de la question -> similarité cosinus contre rag/index.json
# -> extraits injectés en contexte, avec consigne de citer la fiche utilisée.
#
# -ChatModel permet de comparer plusieurs modèles sans éditer le script, ex. :
#   .\chat_test.ps1 -ChatModel qwen2.5:3b-instruct
# -TopK réduit le nombre d'extraits injectés (moins de texte en contexte =
#   generation plus rapide sur CPU, cf. rag/README.md), ex. -TopK 2
param(
    [string]$ChatModel = "mistral",
    [int]$TopK = 3
)

$ollamaUrl = "http://192.168.1.82:11434"
$chatModel = $ChatModel
$embedModel = "nomic-embed-text"
$indexPath = Join-Path $PSScriptRoot "index.json"
$topK = $TopK
$minScore = 0.35

$systemPrompt = "Tu t'appelles Nora, une assistante incarnée dans un avatar 3D, passionnée de contre-cultures (skinheads, punk, antifascisme). Tu es vive, chaleureuse et un peu taquine. Tu réponds en français, à l'oral, en 1 à 3 phrases courtes et naturelles. Pas de listes, pas de markdown, pas d'emojis. Règle absolue, même sans extraits fournis ce tour-ci : n'invente jamais un fait précis (nom, date, chiffre, citation) sur les contre-cultures, et ne cite jamais une source que tu n'as pas reçue dans ce tour (jamais Wikipédia, tu n'y as pas accès). Si tu n'es pas sûre, dis-le simplement plutôt que d'inventer. Distingue toujours ce que tu sors de tes documents (et dis lesquels) de ce qui est ton interprétation ou ton avis à toi."

Write-Host "Chargement de l'index RAG..."
$index = Get-Content $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "Index charge : $($index.count) extraits ($($index.model))`n"

function Get-Embedding($text) {
    $body = @{ model = $embedModel; prompt = $text; options = @{ num_ctx = 8192 } } | ConvertTo-Json -Depth 5
    $resp = Invoke-RestMethod -Uri "$ollamaUrl/api/embeddings" -Method Post -Body $body -ContentType "application/json"
    return $resp.embedding
}

function Get-Cosine($a, $b) {
    $dot = 0.0; $na = 0.0; $nb = 0.0
    for ($i = 0; $i -lt $a.Length; $i++) {
        $dot += $a[$i] * $b[$i]
        $na += $a[$i] * $a[$i]
        $nb += $b[$i] * $b[$i]
    }
    if ($na -eq 0 -or $nb -eq 0) { return 0 }
    return $dot / ([math]::Sqrt($na) * [math]::Sqrt($nb))
}

# $history (le tour precedent, user+assistant) est colle a $query avant
# l'embedding -- sans ca, une relance qui ne renomme pas le sujet (ex. "le
# sens des deux acronymes" apres avoir parle de RASH/SHARP) peut rater la
# fiche pourtant trouvee au tour juste avant. Pas d'appel LLM ici, juste du
# texte en plus avant l'embedding -- cout quasi nul (cf. rag/README.md).
function Search-Rag($query, $history) {
    if ($null -eq $history) { $history = @() }
    $n = [math]::Min(2, $history.Count)
    $recentText = if ($n -gt 0) { ($history[(-$n)..(-1)] | ForEach-Object { $_.content }) -join " " } else { "" }
    $searchQuery = if ($recentText) { "$recentText $query" } else { $query }
    $qVec = Get-Embedding $searchQuery
    $scored = foreach ($e in $index.entries) {
        [PSCustomObject]@{ Entry = $e; Score = Get-Cosine $e.embedding $qVec }
    }
    $scored | Where-Object { $_.Score -ge $minScore } | Sort-Object Score -Descending | Select-Object -First $topK
}

# Le score cosinus seul ne separe pas sujet/hors-sujet pour ce modele
# d'embedding (verifie empiriquement : "tarte aux pommes" score plus haut
# que "mouvement SHARP"). On demande donc au modele de chat lui-meme, vite
# et sur peu de tokens, si CE message appelle la base documentaire -- soit
# il porte sur le sujet, soit il poursuit un fil deja engage (d'ou
# l'historique recent en contexte). "Bonjour" repond NON, pas de recherche.
$ragTriggerPrompt = @"
Tu réponds UNIQUEMENT par un mot : OUI ou NON.
Réponds OUI si le dernier message de l'utilisateur porte sur les contre-cultures (skinheads, punk, antifascisme, reggae, Rock Against Racism, etc.), ou pose une question qui poursuit un sujet de ce type déjà engagé dans la conversation.
Réponds NON pour une salutation, un remerciement, une formule de politesse ou d'au revoir, du small talk, ou tout autre sujet -- même si la conversation portait sur les contre-cultures juste avant.

Exemples :
"Bonjour !" -> NON
"Ca va toi ?" -> NON
"Tu connais le mouvement SHARP ?" -> OUI
"Et ca a pris en France aussi ?" (apres avoir parle de SHARP) -> OUI
"Ok merci, bonne soiree" -> NON
"Quelle est la meilleure recette de tarte aux pommes ?" -> NON
"@

$triggerTimeoutSec = 30

# Renvoie un statut explicite (Status: ok/timeout/error) plutot qu'un simple
# booleen -- un echec technique ne doit jamais s'afficher comme "le modele a
# decide NON". Decision n'a de sens que si Status -eq "ok".
function Test-WantsRag($query, $history) {
    # $history doit etre un VRAI tableau (jamais $null) -- voir le site
    # d'appel plus bas, qui force @(...) autour du pipeline pour ca.
    if ($null -eq $history) { $history = @() }
    $recentHistory = if ($history.Count -gt 6) { $history[-6..-1] } else { $history }
    $triggerMessages = @(@{ role = "system"; content = $ragTriggerPrompt }) + $recentHistory + @(@{ role = "user"; content = $query })
    $body = @{ model = $chatModel; messages = $triggerMessages; max_tokens = 3; temperature = 0 } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Uri "$ollamaUrl/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -TimeoutSec $triggerTimeoutSec
        $raw = $resp.choices[0].message.content
        return [PSCustomObject]@{
            Status   = "ok"
            Decision = $raw.Trim().ToUpper().StartsWith("OUI")
            Raw      = $raw
            Error    = $null
        }
    } catch {
        $msg = $_.Exception.Message
        $isTimeout = $msg -match "(?i)time(d)?.?out|cancel(l)?ed"
        return [PSCustomObject]@{
            Status   = if ($isTimeout) { "timeout" } else { "error" }
            Decision = $false
            Raw      = $null
            Error    = $msg
        }
    }
}

function Format-RagContext($hits) {
    if (-not $hits -or $hits.Count -eq 0) {
        return "Aucun document retrouvé dans ta base de recherche pour cette question. N'invente aucun fait précis (dates, noms, citations) sur les contre-cultures : dis que tu n'as pas ça dans tes sources. Tu peux donner ton avis ou une piste, mais présente-le clairement comme ton interprétation, pas comme un fait documenté."
    }
    $blocks = foreach ($h in $hits) {
        $label = if ($h.Entry.section) { "$($h.Entry.title) — $($h.Entry.section)" } else { $h.Entry.title }
        "Fiche : $label`n$($h.Entry.text)"
    }
    $joined = $blocks -join "`n`n---`n`n"
    return "Extraits de ta base de recherche sur les contre-cultures, trouvés pour cette question :`n`n$joined`n`nRègle : quand tu t'appuies sur un extrait ci-dessus, dis d'où ça vient (nomme la fiche, ex. ""d'après ma fiche sur l'AFA-PB...""). Reformule avec tes mots, ne recopie pas le texte tel quel, et n'ajoute aucun détail précis (nom, date, groupe, chiffre, titre) qui n'est pas dans l'extrait, même s'il te semble plausible. Si ces extraits ne couvrent pas vraiment la question posée, dis-le au lieu d'inventer. Si l'extrait exprime une réserve, une nuance ou un doute (ex. ""rien ne permet de dire que..."", ""relu depuis comme..."", ""ne pas assimiler à...""), restitue cette réserve dans ta réponse au lieu de la transformer en certitude. Toute interprétation ou idée qui vient de toi et pas des extraits doit être présentée comme ton avis."
}

$messages = @(@{ role = "system"; content = $systemPrompt })

Write-Host "Chat avec Nora + RAG (modele: $chatModel, topK: $topK, tape 'exit' pour quitter)`n"

while ($true) {
    $userInput = Read-Host "Toi"
    if ($userInput -in @("exit", "quit")) { break }

    $historySoFar = @($messages | Select-Object -Skip 1)

    $swTrigger = [System.Diagnostics.Stopwatch]::StartNew()
    $trigger = Test-WantsRag $userInput $historySoFar
    $swTrigger.Stop()
    $triggerElapsed = [math]::Round($swTrigger.Elapsed.TotalSeconds, 1)
    switch ($trigger.Status) {
        "ok" {
            Write-Host "  [trigger ${triggerElapsed}s] decision=$(if ($trigger.Decision) {'OUI'} else {'NON'})  (brut: '$($trigger.Raw)')" -ForegroundColor DarkGray
        }
        "timeout" {
            Write-Host "  [trigger ${triggerElapsed}s] TIMEOUT (>${triggerTimeoutSec}s) -- RAG desactive par defaut pour ce tour, PAS une decision du modele" -ForegroundColor Yellow
        }
        "error" {
            Write-Host "  [trigger ${triggerElapsed}s] ERREUR: $($trigger.Error) -- RAG desactive par defaut pour ce tour, PAS une decision du modele" -ForegroundColor Red
        }
    }
    $wantsRag = $trigger.Status -eq "ok" -and $trigger.Decision

    $ragContext = ""
    if ($wantsRag) {
        $swRag = [System.Diagnostics.Stopwatch]::StartNew()
        $hits = Search-Rag $userInput $historySoFar
        $swRag.Stop()
        if ($hits) {
            Write-Host "  [rag $([math]::Round($swRag.Elapsed.TotalSeconds,1))s] $($hits.Count) extrait(s) : $($hits.Entry.id -join ', ')" -ForegroundColor DarkGray
        } else {
            Write-Host "  [rag $([math]::Round($swRag.Elapsed.TotalSeconds,1))s] aucun extrait pertinent" -ForegroundColor DarkGray
        }
        $ragContext = Format-RagContext $hits
    }

    $turnMessages = $messages + @(if ($ragContext) { @{ role = "system"; content = $ragContext } }) + @(@{ role = "user"; content = $userInput })
    $body = @{ model = $chatModel; messages = $turnMessages } | ConvertTo-Json -Depth 6

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Uri "$ollamaUrl/v1/chat/completions" -Method Post -Body $body -ContentType "application/json"
    $sw.Stop()

    $reply = $response.choices[0].message.content
    $messages += @{ role = "user"; content = $userInput }
    $messages += @{ role = "assistant"; content = $reply }

    Write-Host "Nora ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s): $reply`n"
}
