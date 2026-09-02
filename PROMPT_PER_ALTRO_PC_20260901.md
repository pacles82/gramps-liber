# PROMPT PER AGENT AI - Applica patch rel_graph completa su altro PC

Sei un agente su un PC Linux con GrampsWeb via docker-compose già funzionante (immagine ghcr.io/gramps-project/grampsweb:latest, Python 3.13). Devi applicare la patch finale del report Relationship Graph (rel_graph) con stemmi città + foto persone. Lavori in autonomia; chiedi solo se mancano file o credenziali.

## File consegnati (chiedi all'utente dove li ha messi se non li trovi)

- `grampsweb_patch_20260901.tar.gz` (7.8M) creato il 2026-09-01, contiene:
  - `grampsweb/gvrelgraph.py` - plugin GIÀ PATCHATO definitivo
  - `grampsweb/gvrelgraph.patch` - diff -u vs originale (472 righe)
  - `grampsweb/gvrelgraph_ORIGINAL.py` - riferimento
  - `grampsweb/coatofarms/` - override PNG/SVG (Castagnole_Monferrato, Contra_di_Missaglia, Felizzano, Fubine, Giaveno_TO, Giovinazzo, Missaglia, Montemagno, Refrancore, Toritto, Viarigi + **Torre_d_Isola.png/.svg/.w30.png**)
  - `grampsweb/docker-compose.yml` - esempio volumi
  - `grampsweb/PROMPT_PATCH_REL_GRAPH.md` - doc dettagliata (leggerla prima di toccare codice)

Se hai ricevuto solo i file sciolti, cercali in `~/`, `/tmp/`, `~/grampsweb/`, `~/Downloads/`.

## Obiettivo patch (stato finale 2026-09-01)

1. Stemmi per **nascita, morte, residenza** (persone) e **matrimonio** (famiglie) - anche se stessa città, vanno mostrati stemmi distinti per ogni evento (es. `Barletta - Barletta` -> 2 icone affiancate). Matrimoni devono avere 1 stemma solo (no 2x/3x duplicati da leak).
2. Fix leak `__add_family():462` -> `self._coa_rows = []` per resettare accumulatore stemmi per ogni famiglia (altrimenti 2x/3x Barletta nei box matrimoni).
3. Fix apostrofo `Torre d'Isola` -> `get_place_with_coa():964` usa `html.unescape(place).split(",")[0]` altrimenti cerca `Torre_d_x27_Isola` e fallisce. Necessario per città con `'` (es. Torre d'Isola, Sant'Agata).
4. Fix `TITLE` doppia escape: `html.escape(html.unescape(_place))` in `get_person_label():887`.
5. No dedup per stessa città nello stesso nodo (voluto: nascita/morte/residenza anche se stessa città mostrano icone separate). La dedup precedente è stata rimossa.
6. Foto persone: fix `_resolve_media_path` + `_get_person_photo` (60px Pillow in `/tmp/personphotos`).

## Passi esecuzione

### 1. Individua installazione
```bash
docker ps  # cerca grampsweb-grampsweb-1, grampsweb_celery, grampsweb_redis
docker inspect grampsweb-grampsweb-1 --format '{{ json .Mounts }}' | python3 -m json.tool
# trova docker-compose.yml (tipico ~/grampsweb/docker-compose.yml, /opt/grampsweb, ecc.)
# verifica versione Python: docker exec grampsweb-grampsweb-1 ls /venv/lib/
```

### 2. Estrai patch
```bash
tar xzf ~/grampsweb_patch_20260901.tar.gz -C ~/
# oppure se hai già cartella grampsweb, sovrascrivi:
# tar xzf ... -C /tmp && cp -r /tmp/grampsweb/* ~/grampsweb/
ls -lh ~/grampsweb/coatofarms/ | grep Torre
ls -lh ~/grampsweb/gvrelgraph.py
```

### 3. Posiziona file
Metti `gvrelgraph.py` e `coatofarms/` accanto al `docker-compose.yml` (NON in /tmp host). Esempio se compose è in `~/grampsweb/`:
```bash
mkdir -p ~/grampsweb/coatofarms
cp ~/grampsweb_patch_extracted/grampsweb/coatofarms/* ~/grampsweb/coatofarms/
cp ~/grampsweb_patch_extracted/grampsweb/gvrelgraph.py ~/grampsweb/gvrelgraph.py
```

### 4. Modifica docker-compose.yml
Nel servizio `grampsweb` aggiungi (adatta `Source` al tuo path host assoluto):
```yaml
services:
  grampsweb: &grampsweb
    volumes:
      - "/home/TUO_UTENTE/grampsweb/coatofarms:/venv/share/coatofarms"
      - "/home/TUO_UTENTE/grampsweb/gvrelgraph.py:/venv/lib/python3.13/site-packages/gramps/plugins/graph/gvrelgraph.py"
      - gramps_tmp:/tmp  # già presente, serve per cache condivisa /tmp/coatofarms e /tmp/personphotos tra web e celery
```
- Destinazioni a destra sono FISSE. Se `docker exec ... ls /venv/lib/` non è `python3.13`, adatta il path del plugin.
- Se il service `grampsweb_celery` non usa `<<: *grampsweb`, aggiungi gli stessi 2 bind mount anche lì.
- Porta pubblica: cambia solo lato host di `"5055:5000"`.

Verifica env presenti: `GRAMPSWEB_MEDIA_PREFIX_TREE: "true"` e `GRAMPSWEB_MEDIA_BASE_DIR: /app/media` (default).

### 5. Ricrea e riavvia (CRITICO)
Il report in GET sincrona gira nel WEB SERVER, non in celery -> dopo ogni modifica riavvia ENTRAMBI:
```bash
docker compose up -d --force-recreate
docker restart grampsweb-grampsweb-1 grampsweb_celery
# o nomi reali trovati al punto 1
```

### 6. Verifica end-to-end (event_choice con LUOGHI)

Event_choice deve essere 2,3,5,6,7 per vedere luoghi/stemmi (1 e 4 solo date -> no stemmi). Usa `includeCoatsOfArms=True`.

```bash
TOKEN=$(curl -s -X POST http://localhost:5055/api/token/ \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
echo $TOKEN | cut -c1-50

OPTIONS='{"includeCoatsOfArms":"True","event_choice":"2","includeImages":"True","off":"dot","coaWidth":"30","pid":"I0002","filter":"0"}'
ENC=$(python3 -c "import urllib.parse;print(urllib.parse.quote('''$OPTIONS'''))")
curl -s "http://localhost:5055/api/reports/rel_graph/file?jwt=$TOKEN&options=$ENC" -o /tmp/test.gv
grep -c "coatofarms" /tmp/test.gv  # atteso >0
grep -c "personphotos" /tmp/test.gv
grep -c "image-missing" /tmp/test.gv  # deve essere 0

# Test specifici post-fix:
# Pasquale Corcella I0002: nascita Trani + residenza Torre d'Isola -> 2 stemmi distinti
grep -A2 '"I0002"' /tmp/test.gv | grep coatofarms
# atteso: Trani_w30.png + Torre_d_Isola_w30.png  (3 IMG totali con foto persona)

# Luigi Doronzo I0961: Barletta - Barletta -> 2 stemmi identici affiancati (voluto)
python3 - << 'PY'
import re
txt=open("/tmp/test.gv").read()
import re
for gid in ["I0961","I0962","I0959"]:
    m=re.search(r'"%s".*?>> \];'%gid, txt, re.DOTALL)
    if m:
        c=m.group(0).count("coatofarms")
        print(gid, c, "atteso 2 per Barletta-Barletta" if c==2 else "ERRORE")
PY

# Famiglie matrimoni Barletta -> 1 stemma solo (no 2x/3x)
python3 - << 'PY'
import re
txt=open("/tmp/test.gv").read()
dups=[m for m in re.finditer(r'"F\d+" \[.*?label=.*?>> \];', txt, re.DOTALL) if m.group(0).count("coatofarms")>1]
print("famiglie con >1 stemma:", len(dups), "atteso 0")
PY
```

Poi genera PDF reale (`"off":"gvpdf"`) e verifica con `pdfimages -list`.

### 7. Problemi noti

- Graphviz 2.42.4: `Illegal attribute TITLE/WIDTH in <IMG> - ignored` -> normale, resize fisico via Pillow (`*_w30.png` auto-generato). Se cambi `coaWidth`, cancella vecchi `*_w*.png`.
- Override nome file: `re.sub(r"[^a-zA-Z0-9_-]+","_",city).strip("_")[:50]` es. `Giaveno TO`->`Giaveno_TO.png`, `Torre d'Isola`->`Torre_d_Isola.png`. Estensioni cercate: `.png .svg .jpg .jpeg`.
- `Torre d'Isola` non ha P94 su Wikidata Q39667 -> necessario override (già incluso). Se aggiungi nuova città senza P94, scarica da araldicacivica.it e metti in override.
- HTTP 429 da Wikidata se troppi report di fila -> attendi.
- Via/piazza in `place.split(",")[0]` -> prende via, no stemma. Normalizza luoghi o aggiungi override con nome via.
- Frontend vecchio: Ctrl+F5 prima di aprire form report.

## Completamento

Riporta URL (`http://IP:5055`), opzioni form (event_choice con luoghi, Include coats of arms, Coat of arms width 30, Include thumbnails), ed esito verifiche punto 6 (conteggi coatofarms/personphotos, test I0002 2 stemmi, test I0961 2 stemmi, famiglie 1 stemma).
