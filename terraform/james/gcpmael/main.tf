#
# terraform config for GCP / maelstrom cluster
#
# resources:
#   - load balancer
#   - instance group
#   - firewall rule
#   - mysql cluster
#

provider "google" {
  project     = "bitmech-test"
  region      = "us-central1"
  zone        = "us-central1-a"  
}

# VPC network
resource "google_compute_network" "maelstrom_network" {
  name                    = "maelstrom-network"
  provider                = google
  auto_create_subnetworks = false
}

# proxy-only subnet
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "maelstrom-proxy-subnet"
  provider      = google
  ip_cidr_range = "10.0.0.0/24"
  purpose       = "INTERNAL_HTTPS_LOAD_BALANCER"
  role          = "ACTIVE"
  network       = google_compute_network.maelstrom_network.id
}

# backend subnet
resource "google_compute_subnetwork" "maelstrom_subnet" {
  name          = "maelstrom-subnet"
  provider      = google
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.maelstrom_network.id
}

# reserved IP address
resource "google_compute_global_address" "default" {
  name = "xlb-static-ip"
}

# forwarding rule
resource "google_compute_global_forwarding_rule" "default" {
  name                  = "xlb-forwarding-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
  ip_address            = google_compute_global_address.default.id
}

# http proxy
resource "google_compute_target_http_proxy" "default" {
  name     = "xlb-target-http-proxy"
  url_map  = google_compute_url_map.default.id
}

# url map
resource "google_compute_url_map" "default" {
  name            = "xlb-url-map"
  default_service = google_compute_backend_service.default.id
}

# backend service with custom request and response headers
resource "google_compute_backend_service" "default" {
  name                     = "xlb-backend-service"
  protocol                 = "HTTP"
  port_name                = "http"
  load_balancing_scheme    = "EXTERNAL"
  timeout_sec              = 10
  enable_cdn               = false
  custom_request_headers   = ["X-Client-Geo-Location: {client_region_subdivision}, {client_city}"]
  custom_response_headers  = ["X-Cache-Hit: {cdn_cache_status}"]
  health_checks            = [google_compute_health_check.default.id]
  backend {
    group           = google_compute_instance_group_manager.mig2.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# instance health check
resource "google_compute_health_check" "default" {
  name     = "maelstrom-hc"
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

# instance template
resource "google_compute_instance_template" "instance_template" {
  name         = "maelstrom-mig-template"
  provider     = google
  machine_type = "e2-small"
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
      set -euo pipefail

      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y nginx-light jq

      NAME=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/hostname")
      IP=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")
      METADATA=$(curl -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=True" | jq 'del(.["startup-script"])')

      cat <<EOF > /var/www/html/index.html
      <pre>
      Name: $NAME
      IP: $IP
      Metadata: $METADATA
      </pre>
      EOF
    EOF1
  }
  lifecycle {
    create_before_destroy = true
  }
}

# MIG
resource "google_compute_instance_group_manager" "mig2" {
  name     = "maelstrom-mig2"
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
  name = "mig-compute-hc"
  request_path = "/"
  port = "80"
}

resource "google_compute_target_pool" "compute" {
  name = "mig-target-pool"
  session_affinity = "NONE"
  health_checks = [
    "${google_compute_http_health_check.compute.name}",
  ]
}

# allow all access from IAP and health check ranges
resource "google_compute_firewall" "fw-iap" {
  name          = "maelstrom-fw-allow-iap-hc"
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
  name          = "maelstrom-fw-allow-ilb-to-backends"
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
