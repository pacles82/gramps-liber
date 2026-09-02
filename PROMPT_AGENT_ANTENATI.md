# PROMPT PER AGENT AI — Integrare "Antenati" in GrampsWeb locale

Sei un agente che opera su una macchina Linux con un'installazione **GrampsWeb via
docker-compose** già funzionante (container web tipicamente `grampsweb-grampsweb-1`).
L'utente vuole:

1. Installare la **Flask app Antenati** locale (porta 8090) — un portale di ricerca
   registri civili basato sul package pip `antenati`.
2. Aggiungere alla sidebar del frontend GrampsWeb una voce **"Antenati"** che apre,
   integrata nel contenuto della pagina, un iframe puntante a `http://localhost:8090/`.

Lavora in autonomia; chiedi all'utente SOLO i dati mancanti (posizione del compose,
porta host, credenziali admin se diverse da admin/admin).

---

## PARTE A — Installare l'app Antenati (Flask, porta 8090)

### A1. Copia la cartella

La cartella `/home/utente/antenati-web/` va copiata integrale (app.py + venv).
Se non è disponibile sul PC sorgente (installazione completamente nuova), segnala
all'utente che serve crearla: è una Flask app di ~400 righe che wrappa il package
pip `antenati` (v6.1). Senza di essa l'iframe funzionerà ma mostrerà errore.

```bash
# da questo PC:
scp -r /home/utente/antenati-web/ utente@DESTINAZIONE:/home/utente/
# oppure chiavetta USB
```

### A2. Virtual environment e dipendenze

Se il venv della cartella copiata non funziona (es. versione Python diversa),
ricrealo:

```bash
cd /home/utente/antenati-web
python3 -m venv venv
./venv/bin/pip install antenati flask requests
```

Verifica:
```bash
./venv/bin/pip list | grep -iE "antenati|flask|requests"
```

### A3. Accesso LAN (opzionale ma consigliato)

Di default la Flask app ascolta su `127.0.0.1:8090` (solo localhost).
Se GrampsWeb viene consultato da altri dispositivi in rete locale:

```bash
sed -i 's/host="127.0.0.1"/host="0.0.0.0"/' /home/utente/antenati-web/app.py
```

Se è usato SOLO dalla stessa macchina, puoi lasciare `127.0.0.1`.

### A4. Servizio systemd user

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/antenati-web.service << 'EOF'
[Unit]
Description=Antenati web app (Portale Antenati downloader)
After=network.target

[Service]
Type=simple
ExecStart=/home/utente/antenati-web/venv/bin/python /home/utente/antenati-web/app.py
Environment=ANTENATI_WEB_PORT=8090
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now antenati-web.service
```

### A5. Verifica

```bash
systemctl --user status antenati-web.service    # deve essere "active (running)"
curl -s http://localhost:8090/ | head -c 200     # deve restituire HTML
```

---

## PARTE B — Patch del bundle GrampsWeb (sidebar + iframe)

### B1. Individua l'installazione

- `docker ps` → container web/celery/redis, porta host mappata sulla 5000 interna.
- Trova il docker-compose.yml (`docker inspect <container_web> | grep -i composefile`
  o cartelle tipiche ~/grampsweb, /opt/grampsweb).
- Crea una cartella persistente per i file patchati, es.
  `<cartella_compose>/frontend-patch/`.

### B2. Estrai il bundle ORIGINALE dall'immagine (NON dall'host)

Il nome del bundle principale è content-hashed e CAMBIA con la versione
dell'immagine (sul PC di riferimento è `BYLW92JT.js`, altrove può essere diverso):

```bash
BUNDLE=$(docker exec <container_web> sh -c \
  "grep -oE 'src=\"\./[A-Za-z0-9_-]+\.js\"' /app/static/index.html | head -1 | sed 's/src=\"\.\///;s/\"//'")
echo $BUNDLE   # es. BYLW92JT.js

# TAG dell'immagine in esecuzione:
docker inspect <container_web> | grep -m1 Image

# estrai il bundle originale dall'immagine (usa lo stesso TAG):
docker run --rm --entrypoint cat ghcr.io/gramps-project/grampsweb:<TAG> \
  /app/static/$BUNDLE > frontend-patch/bundle_orig.js
cp frontend-patch/bundle_orig.js frontend-patch/bundle_mod.js
```

### B3. Applica le DUE modifiche al bundle

Script python che inserisce la voce menu + accoda l'IIFE in modo sicuro:

```python
import sys

p = "frontend-patch/bundle_mod.js"
data = open(p, encoding="utf-8").read()

assert "data-antenati" not in data, "patch gia applicata"

anchor = '${this._("Map")}\n      </md-list-item>'
assert data.count(anchor) == 1, "ancora Map non trovata o ambigua"

menu_item = (
    '<md-list-item\n'
    '        type="link"\n'
    '        href="#"\n'
    '        data-antenati="1"\n'
    '        onclick="event.preventDefault();window.__antenatiOpen&&__antenatiOpen();return false"\n'
    '      >\n'
    '        ${this._icon("M8,5V14L14,17L14.5,16.9L18.5,10.9L19.2,11.5L14.2,18.5L14,18.6L8,15.6V21H6V5H8M12,2C6.48,2 2,6.48 2,12C2,17.52 6.48,22 12,22C17.52,22 22,17.52 22,12C22,6.48 17.52,2 12,2M12,4C16.42,4 20,7.58 20,12C20,16.42 16.42,20 12,20C7.58,20 4,16.42 4,12C4,7.58 7.58,4 12,4Z","antenati"===t)} Antenati\n'
    '      </md-list-item>'
)

iife = """/* --- Antenati: pagina integrata nel contenuto --- */
(function () {
  var frame = null;
  var hidden = [];
  var observer = null;
  function host() {
    return document.querySelector("gramps-js");
  }
  function mainEl() {
    var h = host();
    return h ? h.shadowRoot.querySelector("main") : null;
  }
  function active() {
    return frame !== null && document.contains(frame);
  }
  function hideDefaults() {
    var m = mainEl();
    if (!m) return;
    hidden = [];
    var kids = m.children;
    for (var i = 0; i < kids.length; i++) {
      if (!kids[i].hasAttribute("data-antenati-frame")) {
        kids[i].style.display = "none";
        hidden.push(kids[i]);
      }
    }
  }
  function showDefaults() {
    for (var i = 0; i < hidden.length; i++) {
      if (hidden[i].isConnected) hidden[i].style.display = "";
    }
    hidden = [];
  }
  function close() {
    if (observer) { observer.disconnect(); observer = null; }
    if (frame) { try { frame.remove(); } catch (e) {} frame = null; }
    showDefaults();
  }
  function open() {
    if (active()) return;
    var m = mainEl();
    if (!m) return;
    frame = document.createElement("iframe");
    frame.src = "http://localhost:8090/";
    frame.style.cssText =
      "width:100%;height:calc(100vh - 120px);border:0;background:#1e1e1e;" +
      "display:block;";
    frame.dataset.antenatiFrame = "1";
    hideDefaults();
    m.appendChild(frame);
    if (observer) observer.disconnect();
    observer = new MutationObserver(function () {
      if (frame && !(mainEl() && mainEl().contains(frame))) close();
    });
    observer.observe(m, { childList: true, subtree: true });
  }
  window.__antenatiOpen = function () {
    if (active()) { close(); return; }
    open();
  };
  window.__antenatiClose = close;
  document.addEventListener("nav", close);
  window.addEventListener("popstate", close);
  document.addEventListener("click", function (e) {
    var path = e.composedPath ? e.composedPath() : [];
    var hitLink = false;
    for (var i = 0; i < path.length; i++) {
      var el = path[i];
      if (!el || !el.tagName) continue;
      var tag = el.tagName.toLowerCase();
      if (tag === "md-list-item" || tag === "a" || tag === "button") {
        hitLink = true;
        if (el.hasAttribute && el.hasAttribute("data-antenati")) break;
        close();
        break;
      }
    }
  }, true);
})();"""

data = data.replace(anchor, anchor + "\n" + menu_item)
data = data.rstrip() + "\n" + iife + "\n"
open(p, "w", encoding="utf-8").write(data)
print("ok: menu item inserito + IIFE accodata")
```

Esegui lo script con il path corretto del bundle_mod.js.

### B4. Patcha index.html (cache-buster)

Copia l'index.html originale dall'immagine e aggiungi il version-param
(preload E script module): se non c'è `?v=`, aggiungi `?v=1`; se c'è, incrementa:

```bash
docker run --rm --entrypoint cat ghcr.io/gramps-project/grampsweb:<TAG> /app/static/index.html \
  > frontend-patch/index.html
sed -i "s|\./$BUNDLE\"|./$BUNDLE?v=1\"|g" frontend-patch/index.html
grep -o "$BUNDLE?v=1" frontend-patch/index.html   # deve comparire 2 volte
```

### B5. Bind mount nel docker-compose.yml

Nel servizio `grampsweb`, sezione `volumes:`:

```yaml
      - "/PERCORSO_HOST/frontend-patch/bundle_mod.js:/app/static/$BUNDLE"
      - "/PERCORSO_HOST/frontend-patch/index.html:/app/static/index.html"
```

(le DESTINAZIONI usano il nome bundle REALE di questa installazione).
Se il compose eredita i volumi al celery via merge key non serve nulla per celery
(file statici usati solo dal web).

### B6. Ricrea e verifica

```bash
docker compose up -d --force-recreate
# index servito col cache-buster:
curl -s http://localhost:PORTA/static/index.html | grep -o "$BUNDLE?v=[0-9]*"
# bundle patchato:
curl -s "http://localhost:PORTA/static/$BUNDLE?v=1" | grep -c "__antenatiOpen"   # >=1
curl -s "http://localhost:PORTA/static/$BUNDLE?v=1" | grep -c "data-antenati"    # >=1
# app Antenati:
curl -s http://localhost:8090/ | head -c 100   # deve rispondere
```

Poi nel browser (Ctrl+F5 per bypassare il service worker): la sidebar deve mostrare
la voce **Antenati** tra "Map" e "DNA"; al click il contenuto viene sostituito da un
iframe con la app sulla :8090; cliccando qualsiasi altra voce della sidebar o
navigando, l'iframe si chiude e il contenuto torna.

---

## PROBLEMI NOTI

- **Nessuna app Antenati sulla porta 8090**: la voce menu appare ma l'iframe è vuoto.
  Verificare con `curl -s http://localhost:8090/` e controllare il systemd service.
- **Accesso da LAN**: se l'iframe non si apre da un altro dispositivo, controllare che
  la Flask app ascolti su `0.0.0.0` (passo A3) e che il firewall non blocchi la 8090.
- **Service worker**: GrampsWeb cachea i bundle. Dopo ogni modifica al bundle incrementare
  il `?v=` in index.html e fare Ctrl+F5 nel browser.
- **Dopo `docker pull`**: il nome del bundle cambia. Rifare i passi B2-B5.
- **Modifiche successive ai file montati** (bind mount): effetto immediato, non serve
  restart. Serve invece ricreare i container quando si AGGIUNGE un nuovo volume.
- **Lo strumento di lettura dei file non apre .png/.jpg**: il tuo modello potrebbe non
  supportare input di immagini. Usare solo shell (ls, python3 PIL) per verificare.
