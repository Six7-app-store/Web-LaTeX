# -----------------------------------------------------------------------------
# Einrichtung der Team-VM beim ersten Boot
#
# Ersetzt das fruehere Packer-Image (ADR 0010 im deployment-Repo). Editor,
# Vorlagen und Demo-Projekt liegen als Dateien unter tofu/files/ und reisen
# gzip+base64 im user_data mit; weblatex-setup.sh installiert danach TeX Live
# und startet den Dienst.
#
# Die Konfiguration wird mit yamlencode gebaut statt als Template: yamlencode
# quotet jeden Wert selbst, auch Teamnamen mit "#" oder ":".
# -----------------------------------------------------------------------------

locals {
  app_files = [
    for f in sort(fileset("${path.module}/files", "**")) : {
      path        = "/opt/weblatex/${f}"
      encoding    = "gz+b64"
      content     = base64gzip(file("${path.module}/files/${f}"))
      permissions = endswith(f, ".sh") ? "0755" : "0644"
    }
  ]

  cloud_init_config = {
    for team in local.teams_list : team => {
      write_files = concat(
        local.app_files,

        # Zugangsdaten, die app.py beim Login liest. Rechte setzt das
        # Setup-Skript, sobald www-data die Gruppe bekommen kann.
        [
          for uid, user in local.users_map : {
            path        = "/etc/weblatex/users/${replace(lower(uid), "/[^a-z0-9_-]+/", "-")}.env"
            permissions = "0600"
            encoding    = "b64"
            content     = base64encode("EMAIL=${user.email}\nPASSWORD=${random_password.user_passwords[uid].result}\n")
          } if user.team == team
        ],

        [
          for slot, file in lookup(var.assignment_files, team, {}) : {
            path        = "/var/lib/weblatex/upload/${basename(file.name)}"
            permissions = "0644"
            encoding    = "b64"
            content     = file.content_b64
          }
        ],

        # ip_mode = dual: die IPv4-Schnittstelle, die OpenTofu nach dem Boot
        # anhaengt. Ihre DHCP-Routen gehen in eine eigene Tabelle, und nur
        # Pakete mit ihrer Adresse als Absender nehmen diese Tabelle. Sonst
        # gingen Antworten ueber die Hauptschnittstelle hinaus, und Neutrons
        # Port-Security verwirft sie als gefaelschten Absender.
        local.dual ? [
          {
            path        = "/etc/netplan/60-secondary-ipv4.yaml"
            permissions = "0600"
            content = yamlencode({
              network = {
                version = 2
                ethernets = {
                  secondary = {
                    match           = { macaddress = local.secondary[team].mac }
                    dhcp4           = true
                    dhcp6           = false
                    accept-ra       = false
                    dhcp4-overrides = { route-table = 100 }
                    routing-policy  = [{ from = local.secondary[team].ipv4, table = 100 }]
                  }
                }
              }
            })
          },
        ] : [],
      )

      runcmd = concat(
        local.dual ? [
          # Die IPv4-Schnittstelle kommt erst nach dem Boot dazu. Bis zu
          # fuenf Minuten auf ihre MAC warten, dann die netplan-Datei oben
          # anwenden. Kommt sie nicht, bleibt die VM ueber IPv6 erreichbar.
          ["sh", "-c", "for i in $(seq 1 60); do if ip -o link | grep -qi \"$1\"; then netplan apply; break; fi; sleep 5; done", "sh", local.secondary[team].mac],
        ] : [],
        [
          # Als letzter Befehl: sein Exit-Code entscheidet, ob cloud-final
          # als fehlgeschlagen gilt.
          ["bash", "/opt/weblatex/weblatex-setup.sh"],
        ],
      )

      final_message = "Web-LaTeX fuer Team ${team} bereit"
    }
  }

  cloud_init = {
    for team, config in local.cloud_init_config : team => "#cloud-config\n${yamlencode(config)}"
  }
}
