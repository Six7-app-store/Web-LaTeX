# OpenTofu erwartet weiterhin das Schluesselwort "terraform"; die Provider
# werden ueber registry.opentofu.org aufgeloest.
terraform {
  required_version = ">= 1.13.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "openstack" {
  cloud = "openstack"
  # Auth via OS_CLOUD + clouds.yaml (oder OS_* env vars)
}

############################
# APP-DEFAULTS
############################

locals {
  app_name = "web-latex"

  # Basis-Image; eingerichtet wird beim ersten Boot per cloud-init
  # (cloud-init.tofu), ein eigenes Image wird nicht gebaut.
  image_name = "Ubuntu 24.04"

  # Systemplatte als Cinder-Volume nur, wenn eine Groesse gewaehlt ist.
  boot_from_volume = var.disk_size_gb > 0
}

############################
# ADRESSFAMILIEN (var.ip_mode)
############################

locals {
  ethertypes = {
    ipv4 = ["IPv4"]
    ipv6 = ["IPv6"]
    dual = ["IPv4", "IPv6"]
  }[var.ip_mode]

  # Bei dual liegt die Hauptschnittstelle im IPv6-Netz: dessen private IPv4
  # bringt den Weg nach draussen (Paketquellen) ueber NAT mit.
  primary_network_id = var.ip_mode == "ipv4" ? var.network_v4_uuid : var.network_uuid

  dual = var.ip_mode == "dual"
}

############################
# USER MANAGEMENT (CONTRACT)
############################

locals {
  # Angemeldet wird im Editor mit der E-Mail-Adresse.
  all_users = flatten([
    for team, members in var.users : [
      for member in members : {
        id    = "${team}-${replace(split("@", member.email)[0], ".", "-")}"
        team  = team
        email = member.email
      }
    ]
  ])

  users_map  = { for user in local.all_users : user.id => user }
  teams_list = distinct([for user in local.all_users : user.team])

  # VM-Name: Teamnamen wie "Team #1" sind als Hostname unzulaessig.
  team_slugs = {
    for team in local.teams_list : team => trim(replace(lower(team), "/[^a-z0-9-]+/", "-"), "-")
  }
}

resource "random_password" "user_passwords" {
  for_each    = local.users_map
  length      = 16
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

# Abbruch vor dem Anlegen, wenn zu viele Teams kommen.
resource "terraform_data" "team_limit" {
  input = length(local.teams_list)

  lifecycle {
    precondition {
      condition     = length(local.teams_list) <= var.max_teams
      error_message = "Dieses Deployment wuerde ${length(local.teams_list)} Team-VMs anlegen, erlaubt sind ${var.max_teams}. Teams zusammenlegen oder max_teams erhoehen."
    }
  }
}

data "openstack_images_image_v2" "image" {
  name        = local.image_name
  most_recent = true
}

############################
# SECURITY GROUP
############################

# Die gemeinsame Security Group gehoert nicht dieser App. Der Editor braucht
# Port 80, und zwar je Adressfamilie: eine IPv4-Regel laesst kein
# IPv6-Paket durch und umgekehrt.
resource "random_id" "secgroup" {
  byte_length = 4
}

resource "openstack_networking_secgroup_v2" "web" {
  # Neutron erlaubt doppelte Namen; der Anhang haelt mehrere Deployments
  # im selben Projekt auseinander.
  name        = "${local.app_name}-${random_id.secgroup.hex}"
  description = "Web-LaTeX-Editor (HTTP, ${var.ip_mode})"
}

resource "openstack_networking_secgroup_rule_v2" "http" {
  for_each = toset(local.ethertypes)

  security_group_id = openstack_networking_secgroup_v2.web.id
  direction         = "ingress"
  ethertype         = each.key
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = each.key == "IPv4" ? "0.0.0.0/0" : "::/0"
  description       = "Web-LaTeX (${each.key})"
}

############################
# EINE VM PRO TEAM
############################

resource "openstack_networking_port_v2" "team" {
  for_each   = toset(local.teams_list)
  name       = "${local.app_name}-${local.team_slugs[each.key]}"
  network_id = local.primary_network_id

  security_group_ids = [
    var.shared_secgroup_id,
    openstack_networking_secgroup_v2.web.id,
  ]
}

# Zweite Schnittstelle fuer dual, vorab als Port angelegt: so sind MAC und
# Adresse schon bekannt, wenn cloud-init sein user-data bekommt.
resource "openstack_networking_port_v2" "team_v4" {
  for_each   = local.dual ? toset(local.teams_list) : toset([])
  name       = "${local.app_name}-${local.team_slugs[each.key]}-v4"
  network_id = var.network_v4_uuid

  security_group_ids = [
    var.shared_secgroup_id,
    openstack_networking_secgroup_v2.web.id,
  ]
}

locals {
  secondary = {
    for team, port in openstack_networking_port_v2.team_v4 : team => {
      mac  = port.mac_address
      ipv4 = one([for ip in port.all_fixed_ips : ip if !strcontains(ip, ":")])
    }
  }
}

resource "openstack_compute_instance_v2" "team_vm" {
  for_each = toset(local.teams_list)

  name        = "${local.app_name}-${local.team_slugs[each.key]}"
  image_id    = local.boot_from_volume ? null : data.openstack_images_image_v2.image.id
  flavor_name = var.flavor

  # Mit gewaehlter Plattengroesse bootet die VM von einem Volume aus dem
  # Image; ohne bleibt es bei der Systemplatte des Flavors.
  dynamic "block_device" {
    for_each = local.boot_from_volume ? [1] : []
    content {
      uuid                  = data.openstack_images_image_v2.image.id
      source_type           = "image"
      destination_type      = "volume"
      volume_size           = var.disk_size_gb
      boot_index            = 0
      delete_on_termination = true
    }
  }

  timeouts {
    create = "15m"
    delete = "15m"
  }

  # Nur die Hauptschnittstelle. Die zweite bei dual haengt interface_attach
  # unten an, sonst bekaeme die VM zwei Default-Routen.
  network {
    port = openstack_networking_port_v2.team[each.key].id
  }

  user_data = local.cloud_init[each.key]

  metadata = {
    team = each.key
    app  = local.app_name
  }

  depends_on = [terraform_data.team_limit, openstack_networking_secgroup_rule_v2.http]

  lifecycle {
    precondition {
      condition     = var.ip_mode == "ipv6" || var.network_v4_uuid != ""
      error_message = "ip_mode \"${var.ip_mode}\" braucht ein IPv4-Netz in network_v4_uuid."
    }
    precondition {
      condition     = var.ip_mode == "ipv4" || var.network_uuid != ""
      error_message = "ip_mode \"${var.ip_mode}\" braucht ein IPv6-Netz in network_uuid."
    }
    # Nova nimmt hoechstens 64 KB user_data an, gemessen nach Base64. Meist
    # sprengt eine zu grosse Aufgaben-ZIP die Grenze.
    precondition {
      condition     = length(base64encode(local.cloud_init[each.key])) <= 65535
      error_message = "Die Einrichtung fuer Team \"${each.key}\" ist zu gross fuer user_data (64 KB). Die Aufgaben-ZIP muss kleiner werden."
    }
  }
}

resource "openstack_compute_interface_attach_v2" "team_v4" {
  for_each    = openstack_networking_port_v2.team_v4
  instance_id = openstack_compute_instance_v2.team_vm[each.key].id
  port_id     = each.value.id
}

############################
# ADRESSEN
############################

# Verbindungsziel je Team. Bei dual die oeffentliche IPv4 der zweiten
# Schnittstelle, weil sie mehr Heimnetze erreicht. Die IPv4 im IPv6-Netz
# ist eine private NAT-Adresse und taugt nicht als Ziel.
locals {
  team_ipv4 = {
    for team in local.teams_list : team => (
      var.ip_mode == "ipv4" ? one([for ip in openstack_networking_port_v2.team[team].all_fixed_ips : ip if !strcontains(ip, ":")])
      : local.dual ? local.secondary[team].ipv4
      : null
    )
  }
  team_ipv6 = {
    for team in local.teams_list : team => (
      var.ip_mode == "ipv4" ? null
      : one([for ip in openstack_networking_port_v2.team[team].all_fixed_ips : ip if strcontains(ip, ":")])
    )
  }
  team_ip = {
    for team in local.teams_list : team => coalesce(local.team_ipv4[team], local.team_ipv6[team])
  }
  team_url = {
    for team, ip in local.team_ip : team => strcontains(ip, ":") ? "http://[${ip}]/" : "http://${ip}/"
  }
}
