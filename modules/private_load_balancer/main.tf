resource "google_dns_record_set" "main" {
  count        = var.dns_create_record ? 1 : 0
  managed_zone = var.dns_zone_name
  # The name must end with a ".".
  name    = var.fqdn
  rrdatas = [var.ip_address]
  ttl     = 300
  type    = "A"
}

resource "google_compute_region_health_check" "lb" {
  name = "${var.namespace}-tfe-interal-lb"

  check_interval_sec = 30
  description        = "The health check of the internal load balancer for TFE."
  timeout_sec        = 4

  https_health_check {
    port         = 443
    request_path = "/_health_check"
  }

}

resource "google_compute_region_backend_service" "lb" {
  region        = "us-west1"
  health_checks = [google_compute_region_health_check.lb.self_link]
  name          = "${var.namespace}-tfe-internal-lb"

  description           = "The backend service of the internal load balancer for TFE."
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_name             = "https"
  protocol              = "HTTPS"
  timeout_sec           = 10

  backend {
    group = var.instance_group

    balancing_mode  = "UTILIZATION"
    description     = "The instance group of the compute deployment for TFE."
    capacity_scaler = 1.0
  }
}

data "google_storage_bucket_object_content" "certificate" {
  name   = "certificate.crt"
  bucket = "terraform-tfe-aux-data"
}

data "google_storage_bucket_object_content" "private_key" {
  name   = "private.key"
  bucket = "terraform-tfe-aux-data"
}

resource "google_compute_region_ssl_certificate" "tfe-cert" {
  region      = "us-west1"
  name        = "tfe-cert"
  private_key = data.google_storage_bucket_object_content.private_key.content
  certificate = data.google_storage_bucket_object_content.certificate.content
}

resource "null_resource" "subnetwork" {
  triggers = {
    this = jsonencode(var.subnetwork)
  }
}

resource "null_resource" "network1" {
  triggers = {
    this = jsonencode(var.network)
  }
}

resource "google_compute_region_url_map" "lb" {
  region          = "us-west1"
  default_service = google_compute_region_backend_service.lb.self_link
  name            = "${var.namespace}-tfe-internal-lb"

  description = "The URL map of the internal load balancer for TFE."
}

resource "google_compute_region_target_https_proxy" "lb" {
  region           = "us-west1"
  name             = "${var.namespace}-tfe-internal-lb"
  ssl_certificates = [google_compute_region_ssl_certificate.tfe-cert.id]
  url_map          = google_compute_region_url_map.lb.self_link

  description = "The target HTTPS proxy of the internal load balancer for TFE."
}

resource "google_compute_subnetwork" "proxy" {
  provider      = google-beta
  name          = "${var.namespace}-tfe-internal-net-proxy"
  ip_cidr_range = "10.78.2.0/26"
  region        = "us-west1"
  network       = var.network # google_compute_network.ilb_network.id
  purpose       = "INTERNAL_HTTPS_LOAD_BALANCER"
  role          = "ACTIVE"
}
resource "google_compute_forwarding_rule" "lb" {
  region   = "us-west1"
  provider = google-beta
  name     = "${var.namespace}-tfe-internal-lb"

  ip_address            = var.ip_address
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  labels                = var.labels
  port_range            = 443
  # subnetwork            = google_compute_subnetwork.proxy.id # var.subnetwork.self_link
  target                = google_compute_region_target_https_proxy.lb.id
  network               = var.network # google_compute_network.ilb_network.id
  subnetwork            = var.subnetwork.self_link # google_compute_subnetwork.ilb_subnet.id
  network_tier          = "PREMIUM"
}

resource "google_compute_router" "router" {
  name    = "${var.namespace}-router"
  network = var.network # google_compute_network.tfe_vpc.self_link
}
resource "google_compute_router_nat" "nat" {
  name                               = "${var.namespace}-router-nat"
  router                             = google_compute_router.router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  drain_nat_ips    = []
  min_ports_per_vm = 4096
  nat_ips          = []

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
