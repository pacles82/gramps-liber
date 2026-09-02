# PROMPT PER AGENT AI — Installazione patch rel_graph su questa macchina

Sei un agente che opera su una macchina Linux con un'installazione **GrampsWeb via
docker-compose** già funzionante. L'utente ti ha consegnato questi file (chiedigli
dove li ha messi se non li trovi):

- `gvrelgraph.py` — plugin Gramps "Relationship Graph" GIÀ PATCHATO: scarica lo
  stemma della città di nascita/morte da Wikidata/Commons (claim P94) con cache su
  disco e cartella di override locale, li ridimensiona fisicamente con Pillow,
  li dispone affiancati in una riga sotto i dati persona; risolve e ridimensiona
  anche le FOTO DELLE PERSONE (fix placeholder image-missing/document.png);
  aggiunge le opzioni `includeCoatsOfArms` (bool) e `coaWidth` (numero 10–120).
- `coatofarms/` — cartella di stemmi PNG RGBA già pronti (override locali).
- `PROMPT_PATCH_REL_GRAPH.md` — documentazione completa con tutto il codice (LEGGERLA
  prima di intervenire sul codice).
- `gvrelgraph.patch` — unified diff contro l'originale (solo se serve ri-applicare
  la patch su una versione diversa del plugin).

Il tuo compito: integrare questi file nell'installazione e verificare end-to-end.
Lavora in autonomia; chiedi all'utente SOLO i dati mancanti (posizione dei file,
credenziali admin se non sono admin/admin, porta desiderata se diversa).

## 1. Individua l'installazione

- `docker ps` per trovare i container (tipicamente `grampsweb-grampsweb-1`,
  `grampsweb_celery`, `grampsweb_redis`) e le porte pubblicate.
- Trova il `docker-compose.yml` del progetto (cartelle tipiche: `~/grampsweb`,
  `/opt/grampsweb`, oppure `docker inspect <container> | grep -i composefile`).
- Annota: cartella del compose, porta host mappata sulla 5000, nomi reali dei
  container web e celery.

## 2. Copia i file in posizione definitiva

Metti `gvrelgraph.py` e `coatofarms/` in una cartella persistente accanto al
docker-compose.yml (es. stessa cartella). NON usare /tmp sul host.

## 3. Modifica il docker-compose.yml

Nel servizio `grampsweb`, sezione `volumes:`, aggiungi DUE bind mount:

```yaml
      - "/PERCORSO_HOST/coatofarms:/venv/share/coatofarms"
      - "/PERCORSO_HOST/gvrelgraph.py:/venv/lib/python3.13/site-packages/gramps/plugins/graph/gvrelgraph.py"
```

Regole rigide:

- Le destinazioni (destra dei due punti) sono FISSE: `/venv/share/coatofarms` e il
  path del plugin dentro il container. Non inventarle.
- ECCEZIONE: verifica la versione Python nel container con
  `docker exec <container_web> ls /venv/lib/`. Se non è `python3.13`, adatta il
  percorso di destinazione del plugin di conseguenza.
- Se il compose usa il merge key YAML (`<<: *grampsweb`) per il servizio celery, i
  volumi si ereditano automaticamente; altrimenti aggiungi gli stessi due mount
  anche al servizio celery.
- Verifica che web e celery condividano `/tmp` tramite volume named
  (es. `- gramps_tmp:/tmp` presente in entrambi): serve per le cache condivise
  `/tmp/coatofarms` (stemmi online) e `/tmp/personphotos` (foto persone).
- PORTA: per cambiare porta pubblica modifica SOLO il lato host di `"5055:5000"`
  (la 5000 interna resta). L'IP non si configura: si usa quello della macchina.

## 4. Ricrea e riavvia

```bash
docker compose up -d --force-recreate
```

REGOLA CRITICA: il report generato dal link download del frontend è una GET
SINCRONA che gira nel processo del WEB SERVER (non in celery). Dopo OGNI modifica
al plugin riavvia ENTRAMBI i container, altrimenti gira il vecchio codice dalla
memoria:

```bash
docker restart <container_web> <container_celery>
```

## 5. Verifica end-to-end

```bash
# login (slash finale obbligatorio su /api/token/)
TOKEN=$(curl -s -X POST http://localhost:PORTA/api/token/ \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

# report in formato graphviz (.gv) per ispezionarlo
OPTIONS='{"includeCoatsOfArms":"True","event_choice":"6","includeImages":"True","off":"dot","coaWidth":"30"}'
ENC=$(python3 -c "import urllib.parse;print(urllib.parse.quote('''$OPTIONS'''))")
curl -s "http://localhost:PORTA/api/reports/rel_graph/file?jwt=$TOKEN&options=$ENC" -o /tmp/test.gv

grep -c "coatofarms"    /tmp/test.gv   # >0 : stemmi presenti
grep -c "personphotos"  /tmp/test.gv   # >0 : foto persone presenti (se il DB ne ha)
grep -c "image-missing" /tmp/test.gv   # DEVE essere 0
```

Poi genera il PDF vero (`"off":"gvpdf"` invece di `"dot"`) e verifica con
`pdfimages -list file.pdf` che ci siano immagini ~30px di larghezza (stemmi) e
~60px (foto persone).

## 6. Problemi noti (leggere PRIMA di debuggare)

- **Niente stemmi ma report ok**: l'opzione `event_choice` deve includere i LUOGHI
  (valori 2, 3, 5, 6, 7). Con choice 1 o 4 (solo date) non compaiono città e quindi
  nessuno stemma. Questo è comportamento corretto.
- **Graphviz 2.42.4 rifiuta l'attributo WIDTH su `<IMG>`** ("Illegal attribute
  WIDTH - ignored"): il ridimensionamento è FISICO via Pillow (`_resize_coa` crea
  `<base>_w<larghezza>.png`). Se si cambia `coaWidth`, cancellare i vecchi
  `*_w*.png` nelle cartelle degli stemmi.
- **Override**: i file in `/venv/share/coatofarms` (bind mount) vincono su tutto.
  Nome file = nome città sanificato con `re.sub(r"[^a-zA-Z0-9_-]+","_",city)[:50]`
  (es. "Giaveno TO" → `Giaveno_TO.png`; "Contra di Missaglia" →
  `Contra_di_Missaglia.png`). Estensioni cercate: `.png .svg .jpg .jpeg`.
- **Foto persone assenti**: il plugin risolve i media con gli env
  `GRAMPSWEB_MEDIA_BASE_DIR` (default `/app/media`) e
  `GRAMPSWEB_MEDIA_PREFIX_TREE` ("true" → sottocartella per tree, tree id =
  basename di `db.get_save_path()`), poi genera miniature 60px in
  `/tmp/personphotos`. Se fallisce: verificare che i file media esistano davvero
  sotto quel path dentro il container.
- **HTTP 429** da Wikidata se si generano molti report di fila: attendere e riprovare.
- **Luoghi-indirizzo** ("Via X, Barletta"): lo split prende `place.split(",")[0]`
  = la via → nessuno stemma. Soluzione: override manuale col nome della via
  sanificato, oppure normalizzare i luoghi nel DB.
- **Frontend vecchio**: dire all'utente di fare Ctrl+F5 prima di aprire il form
  del report.

## 7. Completamento

Riporta all'utente: URL completo del servizio (`http://IP:PORTA`), opzioni da
impostare nel form del report (event_choice con luoghi, "Include coats of arms of
places", "Coat of arms width", "Include thumbnails of people"), e l'esito delle
verifiche del punto 5.
