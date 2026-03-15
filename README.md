# README — Raspberry Pi 3 + Fujitsu fi-6130 + `scanbd` + Paperless-ngx

Dieses Dokument beschreibt ein **funktionierendes, verifiziertes Setup** für einen Raspberry Pi 3 als headless Scan-Station mit einem **Fujitsu fi-6130**. Ziel ist:

- Scan per **Taste am Scanner** über `scanbd`
- Scan per **ADF Duplex**
- schnelle Rückkehr des Scanners in den Bereitschaftszustand durch **Queueing**
- PDF-Erzeugung auf dem Raspberry Pi in einem **separaten Worker**
- Upload in den **Paperless-ngx consume**-Ordner über einen **auf dem Pi gemounteten NFS-Pfad**
- OCR, Tags und Zuordnung anschließend in **Paperless-ngx**

Das Setup basiert auf den tatsächlich funktionierenden Ergebnissen aus der Inbetriebnahme und den relevanten Originaldokumentationen zu Raspberry Pi OS, SANE, `scanbd` und Paperless-ngx. Der fi-6130 wird vom SANE-Backend `fujitsu` unterstützt. `scanbd` überwacht Scanner-Tasten, öffnet den Scanner dafür dauerhaft und sperrt ihn während des Pollings für direkte Zugriffe. Paperless erwartet einen beschreibbaren Consumption-Ordner; bei Docker soll dafür der **Host-Pfad** gemountet werden, nicht nur ein Pfad im Container geändert werden. citeturn270230search0turn800767search0turn265542search0turn939010view2

---

## 1. Zielarchitektur

Der Raspberry Pi hängt per USB am Fujitsu fi-6130 und per Netzwerk am Paperless-Server.

Ablauf:

1. Dokumente in den ADF einlegen
2. Scan-Taste am Fujitsu drücken
3. `scanbd` erkennt den Tastendruck
4. `scanbd` startet das Script `/usr/local/bin/scan-to-paperless.sh`
5. Das Script scannt per `scanimage` nur die **rohen TIFF-Seiten** und legt einen Job in der Queue an
6. Der Scanner ist danach wieder frei, sobald der physische Einzug beendet ist
7. Ein separater `systemd`-Worker verarbeitet die Queue FIFO
8. Der Worker erzeugt das PDF, dreht es bei Bedarf und korrigiert die Seitenreihenfolge
9. Der Worker schreibt das PDF in den per NFS gemounteten Paperless-Consume-Ordner
10. Paperless importiert und OCRt das Dokument

### Verifizierte Besonderheiten dieses Setups

Diese Punkte wurden in der Inbetriebnahme praktisch beobachtet und sind im README bereits berücksichtigt:

- Der fi-6130 wird unter Linux/SANE **ohne separaten proprietären Fujitsu-Treiber** erkannt, über das Backend `fujitsu`.
- Der Scanner war zunächst nur mit `sudo` sichtbar; das wurde über **udev + Gruppe `scanner`** gelöst.
- `scanbd` funktionierte erst zuverlässig, nachdem es ein **eigenes SANE-Konfigurationsverzeichnis** bekommen hat und der Dienst mit `SANE_CONFIG_DIR=/etc/scanbd/sane.d` lief. Genau dieses getrennte Setup wird vom `scanbd`-Projekt für Desktop-/Client-Umgebungen beschrieben. citeturn800767search0turn265542search1turn270230search1
- Die Standard-`scanbd.conf` triggert oft noch `test.script`; das muss auf das echte Script umgestellt werden.
- Der `scanbd`-Button-Trigger funktionierte, nachdem `scanbd` den Fujitsu aus **`/etc/scanbd/sane.d`** sehen konnte.
- Der Scan-Lock darf nicht unter `/run/...` liegen, wenn das Script unter `scanbd` als `saned:scanner` läuft. Ein Lock in `/var/lib/scan-to-paperless/...` war in diesem Setup die funktionierende Lösung.
- Die Seiten mussten in diesem konkreten Setup **um 180° gedreht** und die **Seitenreihenfolge komplett umgedreht** werden, damit das PDF korrekt war.
- Die Ghostscript-basierte Leerseitenerkennung über `inkcov` war mit gräulichem Umweltpapier in diesem Setup nicht zuverlässig; deshalb ist `REMOVE_BLANK_PAGES="false"` der aktuell gewählte stabile Stand.
- Das NFS-Ziel war für `saned:scanner` bereits schreibbar; `chgrp` auf dem Client war auf dem NFS-Mount nicht erlaubt. Das ist normal und muss bei Bedarf serverseitig gelöst werden.
- Die neue Queue trennt **physisches Scannen** von **PDF-Verarbeitung und Upload**. Dadurch ist das Hauptproblem gelöst, dass ein weiterer Scan erst nach kompletter PDF-Nachbearbeitung möglich war.

---

## 2. Voraussetzungen

### Hardware

- Raspberry Pi 3
- Fujitsu fi-6130
- USB-Kabel
- Netzwerkanbindung für den Pi
- Paperless-ngx-Server
- NFS-Export des **echten Host-Consume-Ordners** von Paperless

### Betriebssystem

Empfohlen: **Raspberry Pi OS Lite** für einen headless Betrieb. Raspberry Pi beschreibt den headless Weg über den Imager ausdrücklich: Hostname, Benutzer, Netzwerk und SSH können schon beim Flashen vorkonfiguriert werden. citeturn270230search0turn270230search3

---

## 3. Raspberry Pi OS headless installieren

### 3.1 SD-Karte flashen

Mit **Raspberry Pi Imager**:

- Raspberry Pi OS Lite auswählen
- in den erweiterten Einstellungen setzen:
  - Hostname, z. B. `raspi-scan`
  - Benutzername, z. B. `fabian`
  - WLAN oder LAN
  - SSH aktivieren
  - idealerweise direkt einen SSH-Public-Key hinterlegen

Danach Pi booten und per SSH verbinden:

```bash
ssh fabian@raspi-scan
```

### 3.2 System aktualisieren

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

Raspberry Pi empfiehlt für Raspberry Pi OS explizit `full-upgrade`. citeturn270230search0turn270230search3

---

## 4. Pakete installieren

```bash
sudo apt update
sudo apt install -y sane-utils scanbd ghostscript qpdf img2pdf openssh-client nfs-common util-linux
```

Relevanz der Pakete:

- `sane-utils` liefert u. a. `scanimage` und `sane-find-scanner`
- `scanbd` überwacht Scanner-Tasten
- `ghostscript` wird für PDF-Nachbearbeitung verwendet
- `qpdf` wird für PDF-Drehung und Seitenreihenfolge verwendet
- `img2pdf` erzeugt PDFs aus den gescannten TIFFs
- `nfs-common` wird für den NFS-Mount benötigt
- `util-linux` liefert u. a. `flock` und `mountpoint`

`scanimage` unterstützt Batch-Scans über den ADF. `sane-find-scanner` dient dazu, zu prüfen, ob ein USB-Scanner grundsätzlich vom System erkannt wird. citeturn265542search2turn265542search3

---

## 5. Scanner-Erkennung prüfen

Zuerst prüfen, ob der Scanner USB-seitig auftaucht:

```bash
lsusb
```

Erwartet wurde in diesem Setup:

```text
Bus 001 Device 004: ID 04c5:114f Fujitsu, Ltd fi-6130
```

Dann prüfen, ob SANE den Scanner grundsätzlich erkennt:

```bash
sudo sane-find-scanner
```

Erwartet:

```text
found possible USB scanner (vendor=0x04c5, product=0x114f) at libusb:001:004
```

Wichtig: `sane-find-scanner` bestätigt nur die grundsätzliche Sichtbarkeit über USB; ob ein SANE-Backend tatsächlich scannen kann, prüft anschließend `scanimage -L`. Genau diese Aufgabentrennung beschreibt die SANE-Doku. citeturn265542search3turn265542search1

---

## 6. Rechte für USB-Scanner einrichten

### 6.1 Gruppe `scanner` anlegen und Benutzer hinzufügen

```bash
getent group scanner || sudo groupadd scanner
sudo usermod -aG scanner fabian
```

Danach **neu einloggen**, damit die Gruppenmitgliedschaft aktiv wird.

### 6.2 udev-Regel für den Fujitsu anlegen

Datei:

`/etc/udev/rules.d/60-fujitsu-fi-6130.rules`

Inhalt:

```udev
ATTRS{idVendor}=="04c5", ATTRS{idProduct}=="114f", MODE="0660", GROUP="scanner", ENV{libsane_matched}="yes"
```

Anlegen:

```bash
printf 'ATTRS{idVendor}=="04c5", ATTRS{idProduct}=="114f", MODE="0660", GROUP="scanner", ENV{libsane_matched}="yes"\n' | sudo tee /etc/udev/rules.d/60-fujitsu-fi-6130.rules
```

Regeln neu laden:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Scanner einmal neu anstecken oder aus-/einschalten.

SANE dokumentiert, dass USB-Rechte für Scanner unter Linux üblicherweise per `udev` gesetzt werden und direkte `chmod`-Anpassungen nicht dauerhaft sind. citeturn265542search1turn265542search21

### 6.3 Prüfen, ob der Scanner jetzt ohne `sudo` sichtbar ist

```bash
scanimage -L
```

Wenn der Fujitsu nur mit `sudo scanimage -L` sichtbar ist, stimmt meistens die USB-Berechtigung noch nicht.

---

## 7. Geräteeigenschaften des Fujitsu prüfen

Mit dem fi-6130 wurde erfolgreich geprüft:

```bash
scanimage -A -d 'fujitsu:fi-6130dj:455167'
```

Dabei waren u. a. folgende relevanten Optionen verfügbar:

- `--source ADF Front|ADF Back|ADF Duplex`
- `--mode Lineart|Halftone|Gray|Color`
- `--resolution 50..600dpi`
- `--page-width`
- `--page-height`
- `--scan` als Hardware-Button
- `--email` als weiterer Hardware-Button

Der `fujitsu`-Backend dokumentiert genau diese Art von Optionen und unterstützt die USB-fi-Serie, zu der der fi-6130 gehört. citeturn800767search9turn800767search0

---

## 8. NFS-Mount für den Paperless-Consume-Ordner

### 8.1 Serverseitig

Der **echte Host-Pfad**, der in Docker nach Paperless hineingemountet ist, muss exportiert werden. Paperless dokumentiert ausdrücklich, dass man bei Docker den **Host-Pfad** des Consumption-Ordners korrekt ändern bzw. mounten soll, nicht nur den internen Containerpfad. citeturn939010view2

Beispiel auf dem Server:

```bash
sudo mkdir -p /srv/paperless/consume
```

Export in `/etc/exports`, z. B.:

```exports
/srv/paperless/consume 192.168.178.0/24(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)
```

Dann:

```bash
sudo exportfs -ra
```

### 8.2 Pi-seitig

Mountpunkt anlegen:

```bash
sudo mkdir -p /mnt/paperless-consume
```

Test-Mount:

```bash
sudo mount -t nfs SERVER-IP:/srv/paperless/consume /mnt/paperless-consume
```

Dauerhaft in `/etc/fstab`:

```fstab
SERVER-IP:/srv/paperless/consume  /mnt/paperless-consume  nfs  defaults,_netdev,nofail,x-systemd.automount  0  0
```

Danach:

```bash
sudo mount -a
mount | grep paperless-consume
```

### 8.3 Schreibtest mit dem späteren `scanbd`-Benutzer

Da `scanbd` später als `saned` und Gruppe `scanner` läuft, sollte genau dieser Kontext testen:

```bash
sudo -u saned -g scanner touch /mnt/paperless-consume/.write-test
```

In diesem Setup **funktionierte dieser Test**.  
Ein `chgrp` auf dem NFS-Mount vom Pi aus war **nicht erlaubt**, was bei NFS normal ist und bei Bedarf auf dem Server gelöst werden muss.

---

## 9. Die zentralen Dateien installieren

### 9.1 Script installieren

`/usr/local/bin/scan-to-paperless.sh`

Das Script soll:

- per `scanbd` einen Scanjob enqueuen
- die rohen TIFF-Seiten pro Job lokal ablegen
- per Hintergrund-Worker PDF-Erzeugung und Upload ausführen
- Profile über die Function-Taste des Fujitsu auswählen
- einen kompakten Status der Queue ausgeben

Wichtig:
- Lock-Dateien **nicht** unter `/run`, sondern unter `/var/lib/scan-to-paperless/...`
- das Script muss unter dem Benutzerkontext `saned:scanner` funktionieren

Installieren:

```bash
sudo install -m 0755 scan-to-paperless.sh /usr/local/bin/scan-to-paperless.sh
```

### 9.2 Konfig installieren

`/etc/scan-to-paperless.conf`

Installieren:

```bash
sudo install -m 0644 scan-to-paperless.conf /etc/scan-to-paperless.conf
```

### 9.3 Arbeitsverzeichnisse anlegen und Rechte setzen

```bash
sudo mkdir -p /var/lib/scan-to-paperless/{incoming,queue,processing,failed,spool,archive}
sudo chgrp -R scanner /var/lib/scan-to-paperless
sudo chmod -R 2775 /var/lib/scan-to-paperless
```

### 9.4 Worker-Service installieren

`/etc/systemd/system/scan-to-paperless-worker.service`

Installieren:

```bash
sudo install -m 0644 scan-to-paperless-worker.service /etc/systemd/system/scan-to-paperless-worker.service
sudo systemctl daemon-reload
```

---

## 10. Finale funktionierende Script-Konfiguration

Der verifizierte funktionierende Stand war:

```ini
LOG_TAG="scan-to-paperless"
FILE_PREFIX="import"
KEEP_LOCAL_COPY="false"
STATE_DIR="/var/lib/scan-to-paperless"
LOCK_FILE="/var/lib/scan-to-paperless/scan-to-paperless.lock"
WORKER_LOCK_FILE="/var/lib/scan-to-paperless/scan-to-paperless-worker.lock"

INCOMING_DIR="/var/lib/scan-to-paperless/incoming"
QUEUE_DIR="/var/lib/scan-to-paperless/queue"
PROCESSING_DIR="/var/lib/scan-to-paperless/processing"
FAILED_DIR="/var/lib/scan-to-paperless/failed"
SPOOL_DIR="/var/lib/scan-to-paperless/spool"
ARCHIVE_DIR="/var/lib/scan-to-paperless/archive"

MAX_RETRIES="3"
RETRY_DELAY_MINUTES="5"
WORKER_IDLE_SECONDS="5"
STATUS_LIST_LIMIT="5"

SCAN_DEVICE="fujitsu:fi-6130dj:455167"
SCAN_SOURCE="ADF Duplex"
SCAN_MODE="Gray"
SCAN_RESOLUTION="300"
SCAN_FORMAT="tiff"

SCAN_PAGE_WIDTH="210"
SCAN_PAGE_HEIGHT="297"

SCAN_EXTRA_OPTS="--swdeskew=yes --swcrop=yes --swdespeck=1 --buffermode=On --prepick=On"

REMOVE_BLANK_PAGES="false"
BLANK_THRESHOLD="0.0012"
MIN_PAGES_TO_FILTER="2"

PDF_ROTATION="180"
REVERSE_PAGE_ORDER="true"

EXPECTED_SCANBD_ACTION_REGEX="^scan$"

PROFILE_FROM_SCANBD_FUNCTION="true"
PROFILE_DEFAULT_KEY="1"
FUNCTION_C_VALUES="10 C c"

PROFILE_1_LABEL="Gray Duplex 300dpi"
PROFILE_1_SOURCE="ADF Duplex"
PROFILE_1_MODE="Gray"
PROFILE_1_RESOLUTION="300"

PROFILE_2_LABEL="Gray Single 300dpi"
PROFILE_2_SOURCE="ADF Back"
PROFILE_2_MODE="Gray"
PROFILE_2_RESOLUTION="300"

PROFILE_3_LABEL="Color Duplex 300dpi"
PROFILE_3_SOURCE="ADF Duplex"
PROFILE_3_MODE="Color"
PROFILE_3_RESOLUTION="300"

PROFILE_4_LABEL="Color Single 300dpi"
PROFILE_4_SOURCE="ADF Back"
PROFILE_4_MODE="Color"
PROFILE_4_RESOLUTION="300"

PROFILE_5_LABEL="Lineart Duplex 300dpi"
PROFILE_5_SOURCE="ADF Duplex"
PROFILE_5_MODE="Lineart"
PROFILE_5_RESOLUTION="300"

PROFILE_6_LABEL="Lineart Single 300dpi"
PROFILE_6_SOURCE="ADF Back"
PROFILE_6_MODE="Lineart"
PROFILE_6_RESOLUTION="300"

PROFILE_7_LABEL="Gray Single 600dpi"
PROFILE_7_SOURCE="ADF Back"
PROFILE_7_MODE="Gray"
PROFILE_7_RESOLUTION="600"

PROFILE_8_LABEL="Color Single 600dpi"
PROFILE_8_SOURCE="ADF Back"
PROFILE_8_MODE="Color"
PROFILE_8_RESOLUTION="600"

PROFILE_9_LABEL="Lineart Single 600dpi"
PROFILE_9_SOURCE="ADF Back"
PROFILE_9_MODE="Lineart"
PROFILE_9_RESOLUTION="600"

EMBED_PROFILE_TEXT_LAYER="true"
INVISIBLE_TEXT_PREFIX="paperless-skip-ocr"
INVISIBLE_TEXT_TEMPLATE=""

UPLOAD_METHOD="filesystem"
TARGET_DIR="/mnt/paperless-consume"
TARGET_SUBDIR=""
AUTO_CREATE_TARGET_DIR="false"
REQUIRE_TARGET_MOUNTPOINT="/mnt/paperless-consume"

SFTP_HOST="paperless.example.lan"
SFTP_PORT="22"
SFTP_USER="paperless-ingest"
SFTP_REMOTE_DIR="/srv/paperless/consume"
SFTP_IDENTITY_FILE="/root/.ssh/paperless_scan"
SFTP_STRICT_HOSTKEY="accept-new"
SFTP_CREATE_REMOTE_DIR="false"
```

### Warum genau diese Werte?

- `STATE_DIR` und die Unterverzeichnisse bilden das persistente Queue-Modell.
- `LOCK_FILE` schützt nur den **physischen Scanlauf**, nicht mehr die komplette Verarbeitung.
- `WORKER_LOCK_FILE` stellt sicher, dass nur ein Worker gleichzeitig verarbeitet.
- `MAX_RETRIES="3"` und `RETRY_DELAY_MINUTES="5"` sind ein pragmatischer Standard für temporäre Ziel- oder Netzwerkfehler.
- `SCAN_DEVICE` ist fest gesetzt, damit nicht versehentlich ein anderer Scanner gewählt wird.
- `ADF Duplex` ist der gewünschte Scanmodus.
- `Gray` mit `300` dpi war der ausgewogene, funktionierende Standard.
- A4 wird explizit über `SCAN_PAGE_WIDTH` und `SCAN_PAGE_HEIGHT` gesetzt, weil das Gerät sonst Letter-nahe Defaults meldete.
- `PDF_ROTATION="180"` war nötig, weil die Seiten im konkreten Einzug kopfstehend ankamen.
- `REVERSE_PAGE_ORDER="true"` war nötig, weil der Dokumentstapel sonst im PDF hinten nach vorne ankam.
- `REMOVE_BLANK_PAGES="false"` ist aktuell der stabile Stand, weil die `inkcov`-Methode mit dem verwendeten gräulichen Papier keine brauchbare Leerseitenerkennung ergab.
- `PROFILE_FROM_SCANBD_FUNCTION="true"` erlaubt die Profilwahl `1..9` direkt über die Function-Taste am Scanner.
- `UPLOAD_METHOD="filesystem"` plus NFS-Mount war die gewählte funktionierende Übergabe.
- `EMBED_PROFILE_TEXT_LAYER="true"` kann Paperless/OCRmyPDF im Skip-Modus helfen, das PDF als bereits mit Text versehen zu behandeln.

---

## 11. Warum zuerst immer ohne `scanbd` testen?

Das ist wichtig und war in der Inbetriebnahme entscheidend.

`scanbd` öffnet und pollt den Scanner dauerhaft und **sperrt das Gerät damit für andere direkte Zugriffe**. Deshalb ist der sinnvollste Debug-Ablauf:

1. `scanbd` stoppen
2. Script direkt testen
3. Rechte und Dateiverarbeitung verifizieren
4. erst danach den Button-Trigger aktivieren

Das ist nicht nur praktisch, sondern auch genau so in der `scanbd`-Dokumentation beschrieben: `scanbd` öffnet und pollt den Scanner und blockiert damit andere Zugriffe. citeturn265542search0turn265542search8

---

## 12. Direkter Script-Test ohne `scanbd`

Zuerst `scanbd` stoppen:

```bash
sudo systemctl stop scanbd
```

Dann das Script direkt testen:

```bash
sudo SCANBD_ACTION=scan /usr/local/bin/scan-to-paperless.sh
```

Noch besser ist der Test im späteren echten `scanbd`-Benutzerkontext:

```bash
sudo -u saned -g scanner env SCANBD_ACTION=scan SCANBD_FUNCTION=1 /usr/local/bin/scan-to-paperless.sh
```

Dieser Test legt jetzt **einen Queue-Job** an. Der eigentliche PDF-Workflow läuft anschließend über den Worker.

---

## 13. `scanbd` korrekt konfigurieren

### 13.1 Warum ein separates SANE-Konfigurationsverzeichnis nötig war

Für `scanbd` war ein **eigenes** SANE-Konfigurationsverzeichnis nötig.  
Das `scanbd`-Projekt beschreibt für Desktop-/Client-Betrieb ein getrenntes Setup:

- das normale `/etc/sane.d/dll.conf` enthält nur `net`
- `scanbd` bzw. `saned` verwenden ein separates `SANE_CONFIG_DIR`
- dort sind die **lokalen Backends** wie `fujitsu` aktiviert, aber **nicht** `net`

Genau dieses Modell war hier nötig, damit `scanbd` den Fujitsu zuverlässig pollt. citeturn270230search1

### 13.2 Standard-SANE auf `net` umstellen

`/etc/sane.d/dll.conf`:

```text
net
```

Setzen mit:

```bash
printf 'net\n' | sudo tee /etc/sane.d/dll.conf
```

`/etc/sane.d/net.conf`:

```text
connect_timeout = 3
localhost
```

Setzen mit:

```bash
printf 'connect_timeout = 3\nlocalhost\n' | sudo tee /etc/sane.d/net.conf
```

### 13.3 Eigenes `scanbd`-SANE-Verzeichnis anlegen

```bash
sudo mkdir -p /etc/scanbd/sane.d
sudo cp /etc/sane.d/*.conf /etc/scanbd/sane.d/
```

Dann `dll.conf` für `scanbd` auf **nur** `fujitsu` setzen:

```bash
printf 'fujitsu\n' | sudo tee /etc/scanbd/sane.d/dll.conf
```

Wichtig:  
In diesem Setup musste **die vollständige funktionierende `fujitsu.conf`** in `/etc/scanbd/sane.d/` vorhanden sein. Mit:

```bash
sudo cp /etc/sane.d/fujitsu.conf /etc/scanbd/sane.d/fujitsu.conf
```

konnte erfolgreich geprüft werden:

```bash
sudo systemctl stop scanbd
sudo SANE_CONFIG_DIR=/etc/scanbd/sane.d scanimage -L
```

Erwartetes Ergebnis:

```text
device `fujitsu:fi-6130dj:455167' is a FUJITSU fi-6130dj scanner
```

### 13.4 `scanbd`-Dienst auf das richtige `SANE_CONFIG_DIR` umstellen

Override-Datei anlegen:

`/etc/systemd/system/scanbd.service.d/override.conf`

Inhalt:

```ini
[Service]
Environment=SANE_CONFIG_DIR=/etc/scanbd/sane.d
```

Anlegen:

```bash
sudo mkdir -p /etc/systemd/system/scanbd.service.d
sudo tee /etc/systemd/system/scanbd.service.d/override.conf >/dev/null <<'EOF'
[Service]
Environment=SANE_CONFIG_DIR=/etc/scanbd/sane.d
EOF
```

Aktivieren:

```bash
sudo systemctl daemon-reload
sudo systemctl restart scanbd
```

Prüfen:

```bash
systemctl cat scanbd
```

### 13.5 `scanbd.conf` korrigieren

Die Default-Datei enthält oft noch `test.script`.  
Das ist in diesem Setup der Grund gewesen, warum der Tastendruck zwar erkannt wurde, aber kein echter Scanstart erfolgte.

In `/etc/scanbd/scanbd.conf` den `scan`-Block so setzen:

```conf
action scan {
        filter = "^scan.*"
        numerical-trigger {
                from-value = 1
                to-value   = 0
        }
        desc   = "Scan to Paperless"
        script = "/usr/local/bin/scan-to-paperless.sh"
}
```

Wichtig:

- `scanbd` darf hier **keine Argumente** wie `enqueue` anhängen, da `scanbd` den String direkt als Executable-Pfad ausführt.
- Das ist in Ordnung, weil `/usr/local/bin/scan-to-paperless.sh` standardmäßig `enqueue` ausführt.

Die Debug-Ausgabe hat im funktionierenden Setup klar gezeigt:

- `scanbd` erkennt die Aktion `scan`
- `SCANBD_ACTION=scan` wird gesetzt
- `SCANBD_DEVICE=fujitsu:fi-6130dj:455167` wird gesetzt
- der Fehler lag vorher nur daran, dass noch `test.script` konfiguriert war

---

## 14. `scanbd` im Foreground debuggen

Falls der Button nicht tut, was er soll:

```bash
sudo systemctl stop scanbd
sudo SANE_CONFIG_DIR=/etc/scanbd/sane.d scanbd -f -d7 -c /etc/scanbd/scanbd.conf
```

Dann die Taste drücken.

In diesem Setup war im Debug-Log sichtbar:

- `scanbd` pollt `fujitsu:fi-6130dj:455167`
- die Option `scan` wird erkannt
- die Aktion `scan` wird getriggert
- `SCANBD_ACTION=scan` und `SCANBD_DEVICE=...` werden an das Script übergeben

Erst dieser Debug-Modus hat den letzten Konfigurationsfehler mit `test.script` klar offengelegt.

---

## 15. Paperless-ngx konfigurieren

Relevant für dieses Setup:

- Der Consumption-Ordner muss existieren und vom Paperless-Prozess lesbar und beschreibbar sein.
- Bei Docker soll der **Host-Pfad** korrekt im Compose-Setup gemountet werden.
- Falls Unterordner verwendet werden sollen, gibt es:
  - `PAPERLESS_CONSUMER_RECURSIVE`
  - `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS`
- Wenn Dateisystem-Events nicht zuverlässig erkannt werden, kann Polling aktiviert werden:
  - `PAPERLESS_CONSUMER_POLLING`

Paperless dokumentiert diese Punkte explizit, inklusive der Warnung, dass bei Docker der Host-Pfad und nicht nur der Containerpfad geändert werden soll. citeturn939010view2turn939010view0turn939010view3

### Minimal wichtige Punkte

Wenn der Pi direkt in `/mnt/paperless-consume` schreibt und dieser Pfad auf dem Pi ein NFS-Mount des echten Host-Consume-Ordners ist, reicht meistens:

- Paperless-Consume-Ordner sauber gemountet
- Paperless darf dort lesen
- keine Änderung am Script nötig

Optional:

```env
PAPERLESS_CONSUMER_RECURSIVE=true
PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true
```

nur dann, wenn du später mit Unterordnern arbeiten willst. Paperless dokumentiert, dass `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS` nur zusammen mit `PAPERLESS_CONSUMER_RECURSIVE` funktioniert. citeturn939010view0turn939010view3

Falls neue Dateien nicht erkannt werden:

```env
PAPERLESS_CONSUMER_POLLING=10
```

Paperless dokumentiert, dass damit statt inotify eine periodische Prüfung des Consume-Ordners erfolgt. citeturn939010view2

---

## 16. Endgültige Inbetriebnahme

### 16.1 Dienste starten

```bash
sudo systemctl enable --now scan-to-paperless-worker.service
sudo systemctl enable --now scanbd
sudo systemctl restart scan-to-paperless-worker.service
sudo systemctl restart scanbd
```

### 16.2 Logs beobachten

In einem Terminal:

```bash
journalctl -u scanbd -f
```

Im zweiten:

```bash
journalctl -u scan-to-paperless-worker.service -f
```

Im dritten:

```bash
journalctl -t scan-to-paperless -f
```

### 16.3 Taste drücken

Papier einlegen, dann am Fujitsu die Scan-Taste drücken.

Erwartet:

Im `scanbd`-Log:

- Trigger für Aktion `scan`
- Script `/usr/local/bin/scan-to-paperless.sh` wird gestartet

Im `scan-to-paperless`-Log direkt nach dem Buttondruck:

- `Starte Scan ...`
- `Scan erfolgreich in Warteschlange gelegt ...`

Im Worker-Log:

- `PDF um 180 Grad gedreht`
- `PDF-Seitenreihenfolge umgekehrt`
- `Datei bereitgestellt unter /mnt/paperless-consume/...`
- `Job erfolgreich verarbeitet ...`

**Genau dieser Zustand wurde in diesem Setup erreicht.**

---

## 17. Bekannte und gelöste Stolperfallen

### Problem: nur Netzwerkscanner sichtbar, Fujitsu nicht
Ursache:
- `airscan`/Netzwerk-Backends zeigen den Netzwerkscanner, der Fujitsu wurde aber USB-/SANE-seitig noch nicht sauber erkannt

Lösung:
- `lsusb`
- `sudo sane-find-scanner`
- `scanimage -L` / `sudo scanimage -L`
- udev-Regel + Gruppe `scanner`

### Problem: Fujitsu nur mit `sudo scanimage -L` sichtbar
Ursache:
- USB-Rechteproblem

Lösung:
- udev-Regel
- Benutzer in Gruppe `scanner`
- neu einloggen

### Problem: `scanbd` erkennt Taste nicht
Ursache:
- `scanbd` sah den Fujitsu in seiner eigenen SANE-Konfiguration nicht

Lösung:
- separates `/etc/scanbd/sane.d`
- `SANE_CONFIG_DIR=/etc/scanbd/sane.d`
- `/etc/scanbd/sane.d/dll.conf` auf `fujitsu`
- funktionierende `fujitsu.conf` dort vorhanden

### Problem: Taste wird erkannt, aber nichts passiert
Ursache:
- Standard-`scanbd.conf` startete noch `test.script`

Lösung:
- `script = "/usr/local/bin/scan-to-paperless.sh"`

### Problem: Taste wird erkannt, aber `scanbd` meldet `access/stat/execlp: No such file or directory`
Ursache:
- in `scanbd.conf` wurde fälschlich ein String mit Argumenten gesetzt, z. B. `"/usr/local/bin/scan-to-paperless.sh enqueue"`

Lösung:
- `scanbd`-Script-Eintrag nur auf den Pfad setzen:
  ```conf
  script = "/usr/local/bin/scan-to-paperless.sh"
  ```

### Problem: Script läuft manuell, aber nicht unter `scanbd`
Ursache:
- Lock-Datei lag zuerst unter `/run/...`
- `scanbd` lief als `saned:scanner`

Lösung:
- Lock-Datei nach `/var/lib/scan-to-paperless/...`
- Rechte auf `/var/lib/scan-to-paperless/...` für Gruppe `scanner`
- Test mit:
  ```bash
  sudo -u saned -g scanner env SCANBD_ACTION=scan SCANBD_FUNCTION=1 /usr/local/bin/scan-to-paperless.sh
  ```

### Problem: Scanner ist nach Tastendruck zu lange blockiert
Ursache:
- das alte Script verarbeitete PDF-Erzeugung, Rotation und Upload synchron im gleichen Lauf wie den physischen Scan

Lösung:
- Queue-basiertes Script mit separatem Worker-Service verwenden
- `scanbd` startet nur noch das Enqueueing
- der Worker verarbeitet Jobs danach FIFO im Hintergrund

### Problem: PDF war auf dem Kopf
Lösung:
- `PDF_ROTATION="180"`

### Problem: Seitenreihenfolge war rückwärts
Lösung:
- `REVERSE_PAGE_ORDER="true"`

### Problem: Leerseitenerkennung unzuverlässig
Ursache:
- `inkcov`-Methode war auf dem verwendeten gräulichen Papier nicht brauchbar

Lösung:
- `REMOVE_BLANK_PAGES="false"`

---

## 18. Wichtige Testbefehle

### Scanner erkennen

```bash
lsusb
sudo sane-find-scanner
scanimage -L
sudo scanimage -L
```

### Gerätedetails ansehen

```bash
scanimage -A -d 'fujitsu:fi-6130dj:455167'
```

### Direktes Script testen

```bash
sudo systemctl stop scanbd
sudo SCANBD_ACTION=scan SCANBD_FUNCTION=1 /usr/local/bin/scan-to-paperless.sh
```

### Script im echten `scanbd`-Benutzerkontext testen

```bash
sudo -u saned -g scanner env SCANBD_ACTION=scan SCANBD_FUNCTION=1 /usr/local/bin/scan-to-paperless.sh
```

### Queue-Status prüfen

```bash
/usr/local/bin/scan-to-paperless.sh status
```

### Worker einmalig abarbeiten lassen

```bash
/usr/local/bin/scan-to-paperless.sh worker --once
```

### `scanbd`-eigene SANE-Konfiguration testen

```bash
sudo systemctl stop scanbd
sudo SANE_CONFIG_DIR=/etc/scanbd/sane.d scanimage -L
```

### `scanbd` Foreground-Debug

```bash
sudo systemctl stop scanbd
sudo SANE_CONFIG_DIR=/etc/scanbd/sane.d scanbd -f -d7 -c /etc/scanbd/scanbd.conf
```

---

## 19. Optional: Archivkopie für Debugging

Zum Debuggen kann lokal eine Kopie der fertigen PDF behalten werden:

```ini
KEEP_LOCAL_COPY="true"
```

Dann landen fertige PDFs zusätzlich in:

```text
/var/lib/scan-to-paperless/archive
```

Das war hilfreich, um Rotation, Seitenreihenfolge und die Leerseitenerkennung getrennt zu prüfen.

---

## 20. Aktueller empfohlener stabiler Stand

Für den Alltag ist der stabilste, in diesem Setup funktionierende Stand:

- Raspberry Pi OS Lite
- Fujitsu fi-6130 über SANE `fujitsu`
- `scanbd` mit eigener SANE-Konfiguration
- `scanbd`-Action auf `/usr/local/bin/scan-to-paperless.sh`
- separater `scan-to-paperless-worker.service`
- Upload per NFS in den echten Host-Consume-Ordner
- `SCAN_MODE="Gray"`
- `SCAN_RESOLUTION="300"`
- `REMOVE_BLANK_PAGES="false"`
- `PDF_ROTATION="180"`
- `REVERSE_PAGE_ORDER="true"`
- Profilwahl `1..9` über die Function-Taste
- Queueing mit FIFO-Verarbeitung und Retry

Damit war der komplette Pfad funktionsfähig:

**Taste drücken → ADF Duplex physisch scannen → Job in Queue legen → Worker erzeugt PDF → drehen → Seitenreihenfolge korrigieren → im Consume-Ordner ablegen → Paperless importiert.**

---

## 21. Abschluss

Wenn dieses README auf einen neuen Raspberry Pi angewendet wird, ist die empfohlene Reihenfolge:

1. Raspberry Pi OS Lite headless installieren
2. Pakete installieren
3. USB-Rechte / udev für den Fujitsu setzen
4. Scanner mit `scanimage -L` verifizieren
5. NFS-Mount für den Consume-Ordner einrichten
6. Script und Konfiguration installieren
7. Script **ohne `scanbd`** direkt testen
8. `scanbd`-eigene SANE-Konfiguration aufbauen
9. `scanbd.conf` auf das echte Script umstellen
10. Worker-Service installieren und starten
11. `scanbd` im Foreground debuggen
12. Dienste aktivieren und Button testen

Genau dieser Weg hat in diesem Setup zum funktionierenden Endzustand geführt.
