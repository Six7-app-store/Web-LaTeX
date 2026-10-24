################################################
# Von der Plattform gesetzt
################################################

variable "users" {
  description = "Per-team roster — vom Worker injiziert."
  type = map(list(object({
    email = string
  })))
  default = {}
}

################################################
# Aufgabe
################################################

# Optional. Ohne Upload startet jede Person mit dem Demo-Projekt aus
# tofu/files/demo/. Die Datei reist im user_data der VM mit; Nova begrenzt
# das auf 64 KB, für die ZIP bleiben damit etwa 25 KB.
variable "assignment_files" {
  description = "Startprojekt als ZIP pro Team, mit master.tex im obersten Verzeichnis @openstack:file:team:zip"
  type = map(map(object({
    name         = string
    content_b64  = string
    content_type = string
    size         = number
  })))
  default = {}
}

################################################
# Größe der VM
################################################

variable "flavor" {
  description = "Größe der Team-VM (CPU und Arbeitsspeicher) @openstack:flavor"
  type        = string
  default     = "gp1.small"

  validation {
    condition     = contains(["gp1.small", "gp1.medium", "gp1.large"], var.flavor)
    error_message = "flavor muss gp1.small, gp1.medium oder gp1.large sein."
  }
}

# 0 = die Systemplatte des Flavors (bei gp1 10 GB), ohne Cinder. Jeder andere
# Wert legt die Systemplatte als Cinder-Volume dieser Größe an; es wird mit
# der VM gelöscht.
variable "disk_size_gb" {
  description = "Festplatte in GB (0 = Standardgröße des Flavors)"
  type        = number
  default     = 0

  validation {
    condition     = var.disk_size_gb >= 0 && var.disk_size_gb <= 200
    error_message = "disk_size_gb muss zwischen 0 und 200 liegen."
  }

  # Das Ubuntu-Image braucht mindestens 10 GB. Bewusst als eigener Block mit
  # ">": so liest der Wizard nur den Bereich 0–200 oben als Grenzen.
  validation {
    condition     = var.disk_size_gb == 0 || var.disk_size_gb > 9
    error_message = "disk_size_gb muss 0 oder mindestens 10 sein."
  }
}

# Jedes Team bekommt eine eigene VM. Die Obergrenze schützt das
# Projektkontingent: lieber eine klare Meldung vor dem Apply als ein
# Quota-Fehler mit halbfertigen Instanzen.
variable "max_teams" {
  description = "Obergrenze gleichzeitiger Team-VMs"
  type        = number
  default     = 15

  validation {
    condition     = var.max_teams >= 1 && var.max_teams <= 30
    error_message = "max_teams muss zwischen 1 und 30 liegen."
  }
}

################################################
# Netz
################################################

#   ipv4  eine Schnittstelle im IPv4-Netz (network_v4_uuid)
#   ipv6  eine Schnittstelle im IPv6-Netz (network_uuid) - Standard
#   dual  IPv6-Netz als Hauptschnittstelle, dazu eine zweite im IPv4-Netz
variable "ip_mode" {
  description = "Adressfamilie: ipv4, ipv6 oder dual (beide)"
  type        = string
  default     = "ipv6"

  validation {
    condition     = contains(["ipv4", "ipv6", "dual"], var.ip_mode)
    error_message = "ip_mode muss \"ipv4\", \"ipv6\" oder \"dual\" sein."
  }
}

variable "network_uuid" {
  description = "Netz mit öffentlicher IPv6, z. B. DHBWV6 - für ipv6 und dual @openstack:network:id"
  type        = string
  default     = "9b579624-d844-4df3-b38d-89978b31d37d"
}

variable "network_v4_uuid" {
  description = "Netz mit öffentlich gerouteter IPv4, z. B. DHBWv4 - für ipv4 und dual @openstack:network:id"
  type        = string
  default     = ""
}

variable "shared_secgroup_id" {
  description = "ID der gemeinsamen Security Group für alle VMs @openstack:security_group:id"
  type        = string
  default     = "7ca4f889-e11e-4a16-83a8-73a77ebdbbe6"
}
