# Web-LaTeX Editor

Ein LaTeX-Editor im Browser. Jedes Team bekommt eine eigene VM mit
TeX Live, einem Editor mit Syntax-Highlighting und einer PDF-Vorschau. Die
Mitglieder eines Teams teilen sich die VM, arbeiten aber jeweils in einem
eigenen Projektverzeichnis.

## Funktionen

- PDF-Vorschau nach dem Kompilieren (`pdflatex`, zwei Läufe für
  Inhaltsverzeichnis und Verweise), Kompilieren auch mit `Strg+Enter`
- Datei-Explorer mit mehreren `.tex`-Dateien und Unterverzeichnissen
- Neue `.tex`-Dateien direkt im Browser anlegen
- Bilder (PNG, JPG, GIF, bis 10 MB) hochladen und per `\includegraphics{}`
  einbinden
- Automatisches Speichern 500 ms nach der letzten Eingabe

Installiert sind `texlive-latex-base`, `-latex-recommended`, `-latex-extra`,
`-fonts-recommended` und `-lang-german`.

## User-Management

- **Ein Login pro Person**: Benutzername ist die E-Mail-Adresse, das
  Passwort wird zufällig erzeugt
- Alle Mitglieder eines Teams arbeiten auf **derselben VM**, jede Person in
  ihrem eigenen Verzeichnis unter `/var/www/weblatex/`
- Die Zugangsdaten zeigt der App Store nach dem Deployment an und verschickt
  sie per Mail

## VM-Deployment

| | |
|---|---|
| VMs gesamt | **eine pro Team** (höchstens `max_teams`, Standard 15) |
| Größe | wählbar: `gp1.small`, `gp1.medium`, `gp1.large` (Standard `gp1.small`) |
| Festplatte | wählbar: 10–200 GB, Standard ist die Platte des Flavors (10 GB) |
| Erreichbar über | HTTP auf Port 80, wählbar über IPv6 (Standard), IPv4 oder beides |
| Floating IP | Nein |

## Konfigurierbare Variablen

| Variable | Beschreibung | Standard |
|---|---|---|
| `assignment_files` | Startprojekt als ZIP pro Team, mit `master.tex` im obersten Verzeichnis | leer |
| `flavor` | Größe der Team-VM | `gp1.small` |
| `disk_size_gb` | Festplatte in GB, `0` nutzt die Platte des Flavors | `0` |
| `max_teams` | Obergrenze für Team-VMs in einem Deployment | `15` |
| `ip_mode` | Adressfamilie: `ipv4`, `ipv6` oder `dual` | `ipv6` |
| `network_uuid` | Netz mit öffentlicher IPv6, für `ipv6` und `dual` | `DHBWV6` |
| `network_v4_uuid` | Netz mit öffentlich gerouteter IPv4, für `ipv4` und `dual` | leer |
| `shared_secgroup_id` | ID der gemeinsamen Security Group | `default` |

### Startprojekt (`assignment_files`)

Optional. Lädt der Dozent im Wizard eine ZIP für ein Team hoch, wird sie beim
ersten Start in das Verzeichnis jedes Teammitglieds entpackt. Ohne Upload, oder
wenn die ZIP keine `master.tex` enthält, startet jede Person mit dem
Demo-Projekt aus [`tofu/files/demo/`](tofu/files/demo/).

Die ZIP reist im `user_data` der VM mit, und Nova nimmt davon höchstens 64 KB
an. Für die ZIP bleiben damit etwa **25 KB**. Ist sie größer, bricht der Plan
mit einer Meldung ab, bevor eine VM entsteht.

## Adressfamilie (`ip_mode`)

Wie bei der [Ubuntu-App](https://github.com/Six7-app-store/Ubuntu-App#adressfamilie-ip_mode):
`ipv6` hängt die VM ins Netz `network_uuid`, `ipv4` ins Netz
`network_v4_uuid`, `dual` hängt eine zweite Schnittstelle im IPv4-Netz an,
die cloud-init mit eigener Routing-Tabelle einrichtet. Die Security Group der
App öffnet Port 80 je gewählter Familie. Bei `dual` nennen die Zugangsdaten
die IPv4.

## Einrichtung beim Boot

Es wird kein Image mehr gebaut (ADR 0010 im deployment-Repo). Editor,
Vorlagen und Demo-Projekt liegen unter [`tofu/files/`](tofu/files/) und kommen
komprimiert per cloud-init auf die VM. Danach installiert
[`weblatex-setup.sh`](tofu/files/weblatex-setup.sh) TeX Live und nginx, legt
die Arbeitsverzeichnisse an und startet den Editor.

Das Skript meldet erst Erfolg, wenn der Login über nginx antwortet. Scheitert
ein Schritt, scheitert `cloud-final.service`, und der App Store zeigt das
Deployment als fehlgeschlagen mit den passenden Zeilen aus der Konsole
(ADR 0011). Das Protokoll steht auf der VM in
`/var/log/cloud-init-output.log`.

Die Dauer hängt vor allem an der Installation von TeX Live (mehrere hundert
MB) und ist auf newstack noch nicht gemessen.

## Prüfen ohne Cloud

```bash
cd tofu
tofu init -backend=false
tofu fmt -check -recursive
tofu validate
tofu test
```

Die Tests mocken alle Provider und brauchen keinen OpenStack-Zugang. Die CI
([`.github/workflows/opentofu.yml`](.github/workflows/opentofu.yml)) fährt
dieselben Schritte und prüft zusätzlich das Setup-Skript mit ShellCheck.
