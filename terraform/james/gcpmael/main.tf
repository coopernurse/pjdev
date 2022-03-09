#
# terraform config for GCP / maelstrom cluster
#
# resources:
#   - load balancer
#   - instance group
#   - firewall rule
#   - mysql db
#
#
#  todo:
#    - parameterize the IP addr in user metadata based on private IP of database
#    - make the 'mael' database in mysql
#    - parameterize the root db password
#    - output load balancer ip addr (xlb-url-map)
#
# to ssh:
# gcloud compute ssh --zone "us-central1-a" "vm-x238" --project "bitmech-test" --tunnel-through-iap

provider "google" {
  project     = var.project
  region      = var.region
  zone        = var.zone
}

# VPC network
resource "google_compute_network" "maelstrom_network" {
  name                    = "${var.nameprefix}-maelstrom-network"
  provider                = google
  auto_create_subnetworks = false
}

resource "google_compute_global_address" "private_ip_address" {
  name          = "${var.nameprefix}-private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.maelstrom_network.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.maelstrom_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

# proxy-only subnet
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "${var.nameprefix}-maelstrom-proxy-subnet"
  provider      = google
  ip_cidr_range = "10.0.0.0/24"
  purpose       = "INTERNAL_HTTPS_LOAD_BALANCER"
  role          = "ACTIVE"
  network       = google_compute_network.maelstrom_network.id
}

# backend subnet
resource "google_compute_subnetwork" "maelstrom_subnet" {
  name          = "${var.nameprefix}-maelstrom-subnet"
  provider      = google
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.maelstrom_network.id
}

# reserved IP address
resource "google_compute_global_address" "default" {
  name = "${var.nameprefix}-loadbalancer-ip"
}

# forwarding rule
resource "google_compute_global_forwarding_rule" "default" {
  name                  = "${var.nameprefix}-xlb-fwd-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
  ip_address            = google_compute_global_address.default.id
}

# http proxy
resource "google_compute_target_http_proxy" "default" {
  name     = "${var.nameprefix}-xlb-target-http-proxy"
  url_map  = google_compute_url_map.default.id
}

# url map
resource "google_compute_url_map" "default" {
  name            = "${var.nameprefix}-xlb-url-map"
  default_service = google_compute_backend_service.default.id
}

# backend service with custom request and response headers
resource "google_compute_backend_service" "default" {
  name                     = "${var.nameprefix}-xlb-backend-service"
  protocol                 = "HTTP"
  port_name                = "http"
  load_balancing_scheme    = "EXTERNAL"
  timeout_sec              = 10
  enable_cdn               = false
  custom_request_headers   = ["X-Client-Geo-Location: {client_region_subdivision}, {client_city}"]
  health_checks            = [google_compute_health_check.default.id]
  backend {
    group           = google_compute_instance_group_manager.mig.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# instance health check
resource "google_compute_health_check" "default" {
  name     = "${var.nameprefix}-maelstrom-hc"
  http_health_check {
    port_specification = "USE_SERVING_PORT"
    request_path       = "/_mael_health_check"
  }
}

# instance template
resource "google_compute_instance_template" "instance_template" {
  name         = "${var.nameprefix}-maelstrom-mig-template"
  provider     = google
  machine_type = var.vm_class
  tags         = ["http-server"]

  network_interface {
    network    = google_compute_network.maelstrom_network.id
    subnetwork = google_compute_subnetwork.maelstrom_subnet.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }

  # install nginx and serve a simple web page
  metadata = {
    startup-script = <<-EOF1
      #! /bin/bash

      apt-get update
      apt-get install -y  ca-certificates curl gnupg lsb-release mariadb-client
      cd /usr/local/bin
      curl -LO https://download.maelstromapp.com/latest/linux_x86_64/maelstromd
      curl -LO https://download.maelstromapp.com/latest/linux_x86_64/maelctl
      chmod 755 maelstromd maelctl

      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo   "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io
      systemctl restart docker

      mysqladmin -h ${google_sql_database_instance.mysql.private_ip_address} -u root -p${var.db_password} create mael || true

      cat <<EOF > /etc/systemd/system/maelstromd.service
[Unit]
Description=maelstromd
After=docker.service
[Service]
TimeoutStartSec=0
Restart=always
RestartSec=5
Environment=MAEL_SQL_DRIVER=mysql
Environment=MAEL_SQL_DSN=root:${var.db_password}@(${google_sql_database_instance.mysql.private_ip_address}:3306)/mael
Environment=MAEL_PUBLIC_PORT=80
Environment=MAEL_SHUTDOWN_PAUSE_SECONDS=5
Environment=LOGXI=*=DBG
ExecStartPre=/bin/mkdir -p /var/maelstrom
ExecStartPre=/bin/chmod 700 /var/maelstrom
ExecStart=/usr/local/bin/maelstromd
[Install]
WantedBy=multi-user.target
EOF
      chmod 600 /etc/systemd/system/maelstromd.service
      systemctl daemon-reload
      systemctl enable maelstromd
      systemctl start maelstromd

    EOF1
  }
  lifecycle {
    create_before_destroy = true
  }
}

# MIG
resource "google_compute_instance_group_manager" "mig" {
  name     = "${var.nameprefix}-maelstrom-mig"
  provider = google
  version {
    instance_template = google_compute_instance_template.instance_template.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 1
  target_pools       = ["${google_compute_target_pool.compute.self_link}"]

  named_port {
    name = "http"
    port = "80"
  }  
}

resource "google_compute_http_health_check" "compute" {
  name = "${var.nameprefix}-mig-compute-hc"
  request_path = "/_mael_health_check"
  port = "80"
}

resource "google_compute_target_pool" "compute" {
  name = "${var.nameprefix}-mig-target-pool"
  session_affinity = "NONE"
  health_checks = [
    "${google_compute_http_health_check.compute.name}",
  ]
}

# allow all access from IAP and health check ranges
resource "google_compute_firewall" "fw-iap" {
  name          = "${var.nameprefix}-maelstrom-fw-allow-iap-hc"
  provider      = google
  direction     = "INGRESS"
  network       = google_compute_network.maelstrom_network.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    protocol = "tcp"
  }
}

# allow http from proxy subnet to backends
resource "google_compute_firewall" "fw-maelstrom-to-backends" {
  name          = "${var.nameprefix}-maelstrom-fw-allow-ilb-to-backends"
  provider      = google
  direction     = "INGRESS"
  network       = google_compute_network.maelstrom_network.id
  source_ranges = ["10.0.0.0/24"]
  target_tags   = ["http-server"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }
}

resource "google_sql_user" "users" {
  name = "root"
  instance = "${google_sql_database_instance.mysql.name}"
  host = "%"
  password = "${var.db_password}"
}

resource "google_sql_database_instance" "mysql" {
  name             = "${var.nameprefix}-mysql"
  region           = var.region
  database_version = "MYSQL_8_0"
  deletion_protection = false

  depends_on = [google_service_networking_connection.private_vpc_connection]
  
  settings {
    tier = var.db_tier
    ip_configuration {
      private_network = google_compute_network.maelstrom_network.id
    }
    database_flags {
      name = "character_set_server"
      value = "utf8mb4"
    }    
  }
}

