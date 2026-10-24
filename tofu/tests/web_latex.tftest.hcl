# Prüft, wie Team-VMs, Zugangsdaten und Einrichtung aus den Variablen
# entstehen. Alle Provider sind gemockt: der Test braucht keinen
# OpenStack-Zugang und legt nichts an.
#
#   cd tofu && tofu init -backend=false && tofu test

mock_provider "openstack" {
  mock_data "openstack_images_image_v2" {
    defaults = {
      id = "00000000-0000-0000-0000-00000000image"
    }
  }
  mock_data "openstack_networking_subnet_v2" {
    defaults = {
      gateway_ip = "141.72.10.1"
    }
  }
  mock_resource "openstack_networking_port_v2" {
    defaults = {
      all_fixed_ips = ["141.72.10.7", "2001:db8:4::7"]
      mac_address   = "fa:16:3e:00:00:07"
    }
  }
}

mock_provider "random" {}

variables {
  users = {
    "Team #1" = [{ email = "Anna.Alt@dhbw.de" }, { email = "ben@dhbw.de" }]
    "b"       = [{ email = "cem@dhbw.de" }]
  }
}

run "eine_vm_je_team" {
  command = apply

  assert {
    condition     = length(openstack_compute_instance_v2.team_vm) == 2
    error_message = "Jedes Team braucht genau eine VM."
  }
  assert {
    condition     = openstack_compute_instance_v2.team_vm["Team #1"].name == "web-latex-team-1"
    error_message = "Der VM-Name muss ein gueltiger Hostname sein (\"Team #1\" -> team-1)."
  }
  assert {
    condition     = openstack_compute_instance_v2.team_vm["b"].flavor_name == "gp1.small"
    error_message = "Ohne Auswahl muss gp1.small gelten."
  }
  assert {
    condition     = length(openstack_compute_instance_v2.team_vm["b"].block_device) == 0
    error_message = "disk_size_gb = 0 darf kein Volume anlegen."
  }
}

run "einrichtung_je_team" {
  command = apply

  assert {
    condition     = startswith(local.cloud_init["b"], "#cloud-config\n")
    error_message = "user_data muss mit #cloud-config beginnen."
  }
  assert {
    condition     = length([for f in yamldecode(local.cloud_init["Team #1"]).write_files : f if startswith(f.path, "/etc/weblatex/users/")]) == 2
    error_message = "Auf der VM eines Teams liegen genau die Zugangsdaten seiner Mitglieder."
  }
  assert {
    condition     = strcontains(base64decode(one([for f in yamldecode(local.cloud_init["b"]).write_files : f.content if startswith(f.path, "/etc/weblatex/users/")])), "EMAIL=cem@dhbw.de\n")
    error_message = "app.py liest EMAIL= aus der Zugangsdatei."
  }
  assert {
    condition     = contains([for f in yamldecode(local.cloud_init["b"]).write_files : f.path], "/opt/weblatex/demo/master.tex")
    error_message = "Das Demo-Projekt muss auf der VM liegen."
  }
  assert {
    condition     = alltrue([for f in yamldecode(local.cloud_init["b"]).write_files : f.encoding == "gz+b64" if startswith(f.path, "/opt/weblatex/")])
    error_message = "Die App-Dateien reisen komprimiert, sonst wird user_data zu gross."
  }
  assert {
    condition     = yamldecode(local.cloud_init["b"]).runcmd[length(yamldecode(local.cloud_init["b"]).runcmd) - 1] == ["bash", "/opt/weblatex/weblatex-setup.sh"]
    error_message = "Das Setup-Skript muss zuletzt laufen, sein Exit-Code entscheidet ueber cloud-final."
  }
}

run "aufgabe_nur_fuer_ihr_team" {
  command = apply

  variables {
    assignment_files = {
      "b" = {
        uploaded = {
          name         = "projekt.zip"
          content_b64  = "UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA=="
          content_type = "application/zip"
          size         = 22
        }
      }
    }
  }

  assert {
    condition     = contains([for f in yamldecode(local.cloud_init["b"]).write_files : f.path], "/var/lib/weblatex/upload/projekt.zip")
    error_message = "Die ZIP des Teams muss auf seiner VM landen."
  }
  assert {
    condition     = length([for f in yamldecode(local.cloud_init["Team #1"]).write_files : f if startswith(f.path, "/var/lib/weblatex/upload/")]) == 0
    error_message = "Ein anderes Team darf die ZIP nicht bekommen."
  }
}

run "zu_grosse_aufgabe_wird_abgelehnt" {
  command = plan

  variables {
    assignment_files = {
      "b" = {
        uploaded = {
          name         = "riesig.zip"
          content_b64  = base64encode(join("", [for i in range(1000) : "0123456789012345678901234567890123456789012345678901234567890123"]))
          content_type = "application/zip"
          size         = 50000
        }
      }
    }
  }

  expect_failures = [openstack_compute_instance_v2.team_vm]
}

run "zugang_ueber_ipv6" {
  command = apply

  assert {
    condition     = alltrue([for a in values(output.user_accounts) : a.ip == "2001:db8:4::7" && a.port == 80 && a.protocol == "web"])
    error_message = "Im Standardnetz ist nur IPv6 oeffentlich - die Zugangsdaten muessen sie nennen."
  }
  assert {
    condition     = output.user_accounts["Team #1-Anna-Alt"].username == "Anna.Alt@dhbw.de"
    error_message = "Im Editor meldet man sich mit der E-Mail-Adresse an."
  }
  assert {
    condition     = output.team_vms["b"].url == "http://[2001:db8:4::7]/"
    error_message = "Eine IPv6-Adresse gehoert in der URL in eckige Klammern."
  }
  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.http) == ["IPv6"]
    error_message = "Ohne Auswahl gilt ipv6: nur eine HTTP-Regel fuer IPv6."
  }
  assert {
    condition     = length(openstack_networking_port_v2.team_v4) == 0
    error_message = "ipv6 braucht keine zweite Schnittstelle."
  }
}

run "zugang_ueber_ipv4" {
  command = apply

  variables {
    ip_mode         = "ipv4"
    network_v4_uuid = "00000000-0000-0000-0000-0000000000v4"
  }

  assert {
    condition     = openstack_networking_port_v2.team["b"].network_id == "00000000-0000-0000-0000-0000000000v4"
    error_message = "ipv4 muss die VM ins IPv4-Netz haengen."
  }
  assert {
    condition     = output.team_vms["b"].url == "http://141.72.10.7/"
    error_message = "Die URL muss die IPv4 der VM nennen."
  }
  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.http) == ["IPv4"]
    error_message = "ipv4 braucht genau eine HTTP-Regel fuer IPv4."
  }
}

run "dual_haengt_ipv4_als_zweite_schnittstelle_an" {
  command = apply

  variables {
    ip_mode         = "dual"
    network_v4_uuid = "00000000-0000-0000-0000-0000000000v4"
  }

  assert {
    condition     = length(openstack_compute_interface_attach_v2.team_v4) == 2
    error_message = "dual braucht je Team-VM eine IPv4-Schnittstelle als zweiten Port."
  }
  assert {
    condition     = toset(keys(openstack_networking_secgroup_rule_v2.http)) == toset(["IPv4", "IPv6"])
    error_message = "dual braucht HTTP-Regeln fuer beide Familien."
  }
  assert {
    condition     = output.team_vms["b"].fixed_ip_v6 == "2001:db8:4::7" && output.team_vms["b"].fixed_ip_v4 == "141.72.10.7"
    error_message = "team_vms muss bei dual beide Adressen nennen."
  }
  assert {
    condition     = yamldecode(one([for f in yamldecode(local.cloud_init["b"]).write_files : f.content if f.path == "/etc/netplan/60-secondary-ipv4.yaml"])).network.ethernets.secondary.routing-policy[0].from == "141.72.10.7"
    error_message = "cloud-init muss die IPv4-Schnittstelle mit eigener Routing-Tabelle einrichten."
  }
  assert {
    condition     = yamldecode(one([for f in yamldecode(local.cloud_init["b"]).write_files : f.content if f.path == "/etc/netplan/60-secondary-ipv4.yaml"])).network.ethernets.secondary.routes[0].via == "141.72.10.1"
    error_message = "Die eigene Tabelle braucht die Default-Route ueber das Gateway des IPv4-Netzes."
  }
}

run "zu_viele_teams_werden_abgelehnt" {
  command = plan

  variables {
    max_teams = 1
  }

  expect_failures = [terraform_data.team_limit]
}

run "ipv4_ohne_netz_wird_abgelehnt" {
  command = plan

  variables {
    ip_mode = "ipv4"
  }

  expect_failures = [openstack_compute_instance_v2.team_vm]
}

run "unbekannter_flavor_wird_abgelehnt" {
  command = plan

  variables {
    flavor = "gpu.huge"
  }

  expect_failures = [var.flavor]
}
