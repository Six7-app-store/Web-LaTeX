#!/usr/bin/env bash
# Richtet Web-LaTeX beim ersten Start der VM ein. cloud-init hat vorher
# abgelegt:
#
#   /opt/weblatex/                  Editor, Vorlagen, Demo-Projekt, Unit, nginx
#   /etc/weblatex/users/*.env       EMAIL= und PASSWORD= je Nutzer
#   /var/lib/weblatex/upload/       hochgeladene Aufgabe des Teams (optional)
#
# Bricht das Skript ab, scheitert cloud-final.service, und der App-Store
# meldet das Deployment als fehlgeschlagen (ADR 0011 im deployment-Repo).
set -euo pipefail

log() { echo "[web-latex] $*"; }

BASE_DIR=/var/www/weblatex
UPLOAD_DIR=/var/lib/weblatex/upload

export DEBIAN_FRONTEND=noninteractive
# Beim ersten Boot hält oft apt-daily die dpkg-Sperre; warten statt scheitern.
apt_get() { apt-get -y -q -o DPkg::Lock::Timeout=600 "$@"; }

log "Pakete installieren"
apt_get update
apt_get install --no-install-recommends \
  texlive-latex-base \
  texlive-latex-recommended \
  texlive-latex-extra \
  texlive-fonts-recommended \
  texlive-lang-german \
  nginx \
  python3 \
  python3-flask \
  curl \
  unzip

log "Zugangsdaten schützen"
chown root:www-data /etc/weblatex /etc/weblatex/users
chmod 750 /etc/weblatex /etc/weblatex/users
chown root:www-data /etc/weblatex/users/*.env
chmod 640 /etc/weblatex/users/*.env

# Fester Schlüssel für die Flask-Sitzungen, damit ein Neustart des Dienstes
# niemanden abmeldet.
if [ ! -f /etc/weblatex/flask_secret ]; then
  head -c 32 /dev/urandom > /etc/weblatex/flask_secret
  chown root:www-data /etc/weblatex/flask_secret
  chmod 640 /etc/weblatex/flask_secret
fi

log "Arbeitsverzeichnisse anlegen"
install -d -o www-data -g www-data -m 755 "$BASE_DIR"

for envfile in /etc/weblatex/users/*.env; do
  email=$(sed -n 's/^EMAIL=//p' "$envfile")
  [ -n "$email" ] || continue

  # Gleiche Ableitung wie email_to_dirname() in app.py
  user_dir="$BASE_DIR/$(printf '%s' "$email" | sed 's/@/_/; s/\./-/g')"
  mkdir -p "$user_dir"

  # Aufgabe aus dem Wizard: ZIPs entpacken, alles andere kopieren
  if [ -d "$UPLOAD_DIR" ]; then
    for src in "$UPLOAD_DIR"/*; do
      [ -f "$src" ] || continue
      case "${src,,}" in
        *.zip) unzip -o -q "$src" -d "$user_dir" ;;
        *)     cp "$src" "$user_dir/" ;;
      esac
    done
  fi

  # Ohne master.tex in der Aufgabe startet der Nutzer mit dem Demo-Projekt
  if [ ! -f "$user_dir/master.tex" ]; then
    cp -r /opt/weblatex/demo/. "$user_dir/"
  fi

  # Zweimal übersetzen, damit Inhaltsverzeichnis und Verweise stimmen. Ein
  # Fehler im Dokument soll die Einrichtung nicht abbrechen.
  for _ in 1 2; do
    (cd "$user_dir" && pdflatex -interaction=nonstopmode master.tex > /dev/null 2>&1) || true
  done
  rm -f "$user_dir"/master.{aux,log,out,toc}
  chown -R www-data:www-data "$user_dir"
  log "Arbeitsverzeichnis für $email angelegt"
done

rm -rf "$UPLOAD_DIR"

log "Dienste starten"
chown -R www-data:www-data /opt/weblatex
install -m 644 /opt/weblatex/weblatex.service /etc/systemd/system/weblatex.service
systemctl daemon-reload
systemctl enable --now weblatex

install -m 644 /opt/weblatex/nginx-weblatex.conf /etc/nginx/sites-available/weblatex
ln -sf /etc/nginx/sites-available/weblatex /etc/nginx/sites-enabled/weblatex
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# Erst fertig melden, wenn der Login über nginx antwortet
for _ in $(seq 1 30); do
  if curl -sf -o /dev/null http://localhost/login; then
    log "Editor erreichbar"
    exit 0
  fi
  sleep 2
done

log "Editor antwortet nicht auf http://localhost/login"
systemctl status weblatex --no-pager || true
exit 1
