# PATCH REPORT rel_graph — Stemmi città + Foto persone (GrampsWeb)

## CONTESTO

Installazione GrampsWeb via docker-compose (immagine `ghcr.io/gramps-project/grampsweb:latest`,
Python 3.13 nel container). Vogliamo potenziare il report **Relationship Graph (`rel_graph`)**:

1. **Stemma della città** di nascita/morte accanto al nome di ogni persona:
   - scaricato automaticamente da Wikidata/Commons (claim P94) e messo in cache;
   - ridimensionato fisicamente con Pillow (Graphviz 2.42.4 RIFIUTA l'attributo
     `WIDTH` su `<IMG>`: "Illegal attribute WIDTH - ignored");
   - disposti **affiancati in un'unica riga** sotto i dati persona (non in verticale),
     **senza il nome della città** accanto;
   - supporto **override locale**: una cartella bind-mountata dall'host vince su tutto
     (per città senza stemma su Wikidata o con sfondo da rimuovere).
2. **Foto delle persone** nel grafico (opzione "Include thumbnails of people"):
   - in GrampsWeb `db.get_mediapath()` è None e la thumbnail-cache di Gramps desktop
     (`/root/.cache/gramps/thumb/`) non esiste → le foto risultavano placeholder
     `image-missing.png`/`document.png`;
   - fix: risolvere il path reale con gli env di GrampsWeb
     (`GRAMPSWEB_MEDIA_BASE_DIR` + `GRAMPSWEB_MEDIA_PREFIX_TREE`) e generare la
     miniatura 60px con Pillow in `/tmp/personphotos/`.
3. Nuova opzione **"Coat of arms width"** (NumberOption 10–120, default 30).

## FILE FORNITI (in questa cartella)

- `gvrelgraph.py` — plugin GIÀ PATCHATO, pronto da copiare (basato sulla versione del
  container image di ago 2026; se l'altra installazione ha una versione Gramps diversa,
  applicare invece il patch file).
- `gvrelgraph.patch` — unified diff contro l'originale, applicabile con
  `patch /percorso/gvrelgraph.py < gvrelgraph.patch`
- `gvrelgraph_ORIGINAL.py` — copia dell'originale non modificato (riferimento)
- `coatofarms/` — stemmi override già pronti (vedi sotto)

---

## MODIFICA 1 — Il plugin `gvrelgraph.py`

Il file nel container è:
`/venv/lib/python3.13/site-packages/gramps/plugins/graph/gvrelgraph.py`

### 1a. Import (in cima al file)

Aggiungere `NumberOption` agli import da `gramps.gen.plug.menu`:

```python
from gramps.gen.plug.menu import (
    BooleanOption,
    EnumeratedListOption,
    FilterOption,
    NumberOption,      # <-- AGGIUNTO
    PersonOption,
    ColorOption,
)
```

(`media_path_full`, `find_file`, `get_thumbnail_path` restano importati come prima.)

### 1b. Inizializzazione in `RelGraphReport.__init__`

Subito dopo gli altri `get_value(...)`, aggiungere:

```python
        self.include_coatsofarms = get_value("includeCoatsOfArms")
        self.coa_width = get_value("coaWidth")
```

e poco dopo (con le altre inizializzazioni d'istanza):

```python
        self._coa_cache = {}
```

### 1c. Nuovi metodi della classe `RelGraphReport`

Inserire questi metodi nella classe (ad esempio subito prima di `get_person_label`):

```python
    def _resolve_media_path(self, media):
        """Resolve the on-disk path of a media object.

        Grampsweb stores media under GRAMPSWEB_MEDIA_BASE_DIR, optionally
        prefixed by the tree id. The Gramps DB media path is not set, so
        media_path_full() would fall back to the wrong location.
        """
        fname = media.get_path()
        base_dir = os.environ.get("GRAMPSWEB_MEDIA_BASE_DIR", "")
        prefix_tree = os.environ.get("GRAMPSWEB_MEDIA_PREFIX_TREE", "") == "true"
        if base_dir:
            # tree id = basename of the Gramps DB directory
            tree = ""
            try:
                tree = os.path.basename(self._db.get_save_path() or "")
            except Exception:
                tree = ""
            if prefix_tree and tree:
                full = os.path.join(base_dir, tree, fname)
            else:
                full = os.path.join(base_dir, fname)
            if os.path.isfile(full):
                return full
        # fall back to the standard resolution
        return media_path_full(self._db, fname)

    def _get_person_photo(self, media):
        """Return a small PNG thumbnail of a person photo, or None.

        Grampsweb keeps media under /app/media/<tree>/ and generates its own
        thumbnails; the Gramps desktop thumbnail cache used by
        get_thumbnail_path/find_file is not available inside the containers,
        so we render a small thumbnail with Pillow ourselves.
        """
        src = self._resolve_media_path(media)
        if not src or not os.path.isfile(src):
            return None
        try:
            from PIL import Image

            thumb_dir = os.path.join(tempfile.gettempdir(), "personphotos")
            os.makedirs(thumb_dir, exist_ok=True)
            h = os.path.basename(src)
            target = os.path.join(thumb_dir, "%s.jpg" % re.sub(r"\W+", "_", h))
            if os.path.isfile(target):
                return target
            with Image.open(src) as im:
                im = im.convert("RGB")
                width = 60
                ratio = width / float(im.size[0])
                height = max(1, int(round(im.size[1] * ratio)))
                im = im.resize((width, height), Image.LANCZOS)
                im.save(target, "JPEG", quality=85)
            return target
        except Exception:
            return None

    def get_place_with_coa(self, place):
        """
        Return the place string; registers the city coat of arms for the
        side-by-side stemma row, if it could be retrieved.
        """
        if not place or not self.include_coatsofarms:
            return place
        city = place.split(",")[0].strip()
        path = self._get_coa_path(city)
        if not path:
            return place
        self._coa_rows.append((path, place))
        return place

    def _get_coa_path(self, city):
        """Return the local path of the coat of arms image for a city, or None."""
        if not city:
            return None
        key = city.lower()
        if key in self._coa_cache:
            return self._coa_cache[key]
        coa_dir = os.path.join(tempfile.gettempdir(), "coatofarms")
        safe = re.sub(r"[^a-zA-Z0-9_-]+", "_", city).strip("_")[:50] or "city"
        existing = None
        # a persistent override directory, bind-mounted from the host, wins over
        # anything else and over the online lookup
        for dirname in (
            "/venv/share/coatofarms",
            coa_dir,
        ):
            if not os.path.isdir(dirname):
                continue
            for ext in (".png", ".svg", ".jpg", ".jpeg"):
                cand = os.path.join(dirname, "%s%s" % (safe, ext))
                if os.path.isfile(cand):
                    existing = cand
                    break
            if existing:
                break
        if existing:
            resized = self._resize_coa(existing)
            self._coa_cache[key] = resized or existing
            return self._coa_cache[key]
        path = self._fetch_coa(city)
        if path:
            path = self._resize_coa(path) or path
        self._coa_cache[key] = path
        return path

    def _resize_coa(self, path):
        """Return a version of the coat of arms resized to coa_width points, or None."""
        try:
            from PIL import Image

            width = getattr(self, "coa_width", 30)
            if width <= 0 or width >= 120:
                return None
            base, ext = os.path.splitext(path)
            resized = "%s_w%d.png" % (base, width)
            if os.path.isfile(resized):
                return resized
            with Image.open(path) as im:
                im = im.convert("RGBA")
                ratio = width / float(im.size[0])
                height = max(1, int(round(im.size[1] * ratio)))
                im = im.resize((width, height), Image.LANCZOS)
                im.save(resized, "PNG")
            return resized
        except Exception:
            return None

    def _fetch_coa(self, city):
        """Fetch the coat of arms image from Wikimedia and cache it locally."""
        import requests

        hdr = {"User-Agent": "GrampsWeb-RelGraph/1.0 (grampsweb report)"}
        try:
            # 1. find the Wikidata entity for the city
            r = requests.get(
                "https://www.wikidata.org/w/api.php",
                params={
                    "action": "wbsearchentities",
                    "format": "json",
                    "language": "it",
                    "type": "item",
                    "search": city,
                    "limit": 3,
                },
                headers=hdr,
                timeout=10,
            )
            items = r.json().get("search", [])
            if not items:
                return None
            ids = "|".join(item["id"] for item in items)
            # 2. get claims (P94 = coat of arms image)
            r = requests.get(
                "https://www.wikidata.org/w/api.php",
                params={
                    "action": "wbgetentities",
                    "format": "json",
                    "ids": ids,
                    "props": "claims",
                },
                headers=hdr,
                timeout=10,
            )
            entities = r.json().get("entities", {})
            coa_file = None
            for item in items:
                claims = entities.get(item["id"], {}).get("claims", {})
                for claim in claims.get("P94", []):
                    value = (
                        claim.get("mainsnak", {})
                        .get("datavalue", {})
                        .get("value")
                    )
                    if value:
                        coa_file = value
                        break
                if coa_file:
                    break
            if not coa_file:
                return None
            # 3. get the thumbnail PNG URL from Wikimedia Commons
            r = requests.get(
                "https://commons.wikimedia.org/w/api.php",
                params={
                    "action": "query",
                    "format": "json",
                    "titles": "File:" + coa_file,
                    "prop": "imageinfo",
                    "iiprop": "url",
                    "iiurlwidth": "64",
                },
                headers=hdr,
                timeout=10,
            )
            pages = r.json().get("query", {}).get("pages", {})
            thumb_url = None
            for page in pages.values():
                infos = page.get("imageinfo", [])
                if infos and infos[0].get("thumburl"):
                    thumb_url = infos[0]["thumburl"]
                    break
            if not thumb_url:
                return None
            # 4. download and cache the image
            ext = os.path.splitext(thumb_url.split("?")[0])[1] or ".png"
            coa_dir = os.path.join(tempfile.gettempdir(), "coatofarms")
            os.makedirs(coa_dir, exist_ok=True)
            safe = re.sub(r"[^a-zA-Z0-9_-]+", "_", city).strip("_")[:50] or "city"
            path = os.path.join(coa_dir, "%s%s" % (safe, ext))
            r = requests.get(thumb_url, headers=hdr, timeout=15)
            if r.status_code == 200:
                with open(path, "wb") as fh:
                    fh.write(r.content)
                return path
            return None
        except Exception:
            return None
```

### 1d. Modifiche a `get_person_label`

Sostituire il blocco iniziale che sceglie la foto:

```python
                if media_mime_type[0:5] == "image":
                    image_path = get_thumbnail_path(
                        media_path_full(self._db, media.get_path()),
                        rectangle=media_list[0].get_rectangle(),
                    )
                    # test if thumbnail actually exists in thumbs
                    # (import of data means media files might not be present
                    image_path = find_file(image_path)
```

con:

```python
                if media_mime_type[0:5] == "image":
                    image_path = self._get_person_photo(media)
```

Poi, dove si costruisce la label, inizializzare la lista degli stemmi
(subito prima di costruire `label`):

```python
        label = ""
        line_delimiter = "\\n"
        self._coa_rows = []
```

e cambiare la condizione della tabella HTML in:

```python
        if self.use_html_output and (image_path or self.include_coatsofarms):
```

Alla FINE della costruzione della label, sostituire la chiusura tabella:

```python
        if self.use_html_output:
            label += "</TD></TR>"
            if self._coa_rows:
                label += "<TR>"
                for _path, _place in self._coa_rows:
                    label += '<TD><IMG SRC="%s"/></TD>' % _path
                label += "</TR>"
            label += "</TABLE>"
            return label
```

(gli stemmi finiscono AFFIANCATI in un'unica riga `<TR>` con una `<TD><IMG/></TD>`
ciascuno, SENZA nome città.)

### 1e. Chiamate a `get_place_with_coa`

Nel metodo che compone date/luoghi della persona, sostituire ogni emissione del
luogo di nascita/morte con la chiamata che registra lo stemma. Le 4 occorrenze:

```python
                    label += "%s" % self.get_place_with_coa(b_place)   # nascita
...
                    label += "%s" % self.get_place_with_coa(d_place)   # morte
...
                    label += " %s" % self.get_place_with_coa(b_place)
...
                    label += " %s" % self.get_place_with_coa(d_place)
```

(prima era `self.get_place_string(...)` inline; il metodo ora ritorna comunque la
stringa del luogo e accumula in `self._coa_rows`.)

### 1f. Nuove opzioni in `RelGraphOptions.add_menu_options`

Dopo l'opzione `imageOnTheSide`, aggiungere:

```python
        self.__include_coatsofarms = BooleanOption(
            _("Include coats of arms of places"), False
        )
        self.__include_coatsofarms.set_help(
            _(
                "Whether to fetch and display the coat of arms of each "
                "place of birth and death from Wikimedia."
            )
        )
        add_option("includeCoatsOfArms", self.__include_coatsofarms)

        self.__coa_width = NumberOption(_("Coat of arms width"), 30, 10, 120)
        self.__coa_width.set_help(
            _("Width in points of the coat of arms images")
        )
        add_option("coaWidth", self.__coa_width)
```

> NOTA: il frontend invia i boolean come stringhe `"True"/"False"` e i numeri come
> stringhe (`"30"`): Gramps li converte, funziona così com'è.

---

## MODIFICA 2 — `docker-compose.yml`

Nella sezione `volumes:` del servizio `grampsweb` (che viene ereditata anche dal
servizio celery tramite il merge key `<<: *grampsweb`), aggiungere DUE bind mount:

```yaml
      - "/home/utente/grampsweb/coatofarms:/venv/share/coatofarms"  # stemmi override locali
      - "/home/utente/grampsweb/gvrelgraph.py:/venv/lib/python3.13/site-packages/gramps/plugins/graph/gvrelgraph.py"  # plugin patchato
```

(adattare i path host all'altro PC). Verificare che siano presenti gli env:

```yaml
      GRAMPSWEB_MEDIA_PREFIX_TREE: "true"   # media in sottocartella per tree
```

(`GRAMPSWEB_MEDIA_BASE_DIR=/app/media` è già il default dell'immagine.)
Il volume named condiviso `- gramps_tmp:/tmp` serve perché web e celery condividano
le cache `/tmp/coatofarms` e `/tmp/personphotos`.

## MODIFICA 3 — Cartella override stemmi

Creare sul host la cartella `coatofarms/` (bind-mountata su `/venv/share/coatofarms`).
I file devono chiamarsi col NOME CITTÀ SANIFICATO: `re.sub(r"[^a-zA-Z0-9_-]+","_",city).strip("_")[:50]`
(es. "Giaveno TO" → `Giaveno_TO.png`; "Contra di Missaglia" → `Contra_di_Missaglia.png`).
Estensioni cercate in ordine: `.png .svg .jpg .jpeg`.

Già pronti in `coatofarms/`: Castagnole_Monferrato, Contra_di_Missaglia, Felizzano,
Fubine, Giaveno_TO, Giovinazzo, Missaglia, Montemagno, Refrancore, Toritto, Viarigi
(tutti RGBA con sfondo trasparente). Le versioni `*_w<larghezza>.png` vengono
rigenerate automaticamente dal plugin alla prima esecuzione.

Per aggiungere nuove città senza stemma su Wikidata: scaricare lo stemma
(da araldicacivica.it: `https://www.araldicacivica.it/stemma/<slug>/` e immagine in
`/wp-content/uploads/2016/04/...`), poi rimuovere lo sfondo bianco con flood-fill
dai bordi (script Pillow, soglia >243 sui 3 canali, preservando i bianchi INTERNI
dello stemma), salvare come PNG RGBA col nome sanificato.

## APPLICAZIONE SULL'ALTRO PC

```bash
# 1. copiare i file (gvrelgraph.py + cartella coatofarms) e sistemare i path nel docker-compose.yml
# 2. ricreare i container per applicare i nuovi volumi:
docker compose up -d --force-recreate
# oppure, se i volumi c'erano già:
docker restart grampsweb-grampsweb-1 grampsweb_celery
```

**FONDAMENTALE**: il report sincrono (GET dal link download del frontend) gira nel
processo del WEB SERVER, non in celery → dopo OGNI modifica al plugin riavviare
ENTRAMBI i container, altrimenti gira il vecchio codice dalla memoria.

## USO E VERIFICA

1. Nel form del report (Ctrl+F5 per ricaricare il frontend):
   - **event_choice** deve includere i LUOGHI (valori 2, 3, 5, 6, 7 — es.
     "date+place"): con choice solo-date (1, 4) non ci sono città e quindi niente stemmi;
   - spuntare **"Include coats of arms of places"**;
   - **"Coat of arms width"**: 30 (default);
   - **"Include thumbnails of people"** attivo per le foto;
   - output format **PDF** (gvpdf).
2. Verifica rapida via API (report .gv senza PDF):

```bash
TOKEN=$(curl -s -X POST http://localhost:5055/api/token/ \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
OPTIONS='{"includeCoatsOfArms":"True","event_choice":"6","includeImages":"True","off":"dot","coaWidth":"30"}'
ENC=$(python3 -c "import urllib.parse;print(urllib.parse.quote('''$OPTIONS'''))")
curl -s "http://localhost:5055/api/reports/rel_graph/file?jwt=$TOKEN&options=$ENC" -o test.gv
grep -c "coatofarms" test.gv   # numero IMG stemmi
grep -c "personphotos" test.gv # numero IMG foto persone
grep -c "image-missing" test.gv # deve essere 0
```

3. Possibili problemi:
   - **HTTP 429** da Wikidata se si rigenerano molti report in fretta: attendere;
   - città-indirizzo ("Via X, Barletta") → lo split `place.split(",")[0]` prende la
     via: aggiungere l'override manuale col nome della via sanificato, oppure
     normalizzare i luoghi nel DB;
   - se uno stemma override viene sostituito, cancellare anche il vecchio
     `*_w<width>.png` (il resize è memoizzato su disco);
   - Graphviz potrebbe loggare "Illegal attribute WIDTH" se qualcuno reintroduce
     l'attributo WIDTH su `<IMG>`: NON usare WIDTH, il resize è fisico via Pillow.
