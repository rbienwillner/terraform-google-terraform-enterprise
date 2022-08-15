resource "random_pet" "postgres" {
  length = 2
}

resource "google_compute_global_address" "private_ip_address" {
  provider = google-beta

  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 22
  network       = var.service_networking_connection.network
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = var.service_networking_connection.network
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

resource "google_sql_database_instance" "tfe" {
  name             = "${var.namespace}-tfe-${random_pet.postgres.id}"
  database_version = var.postgres_version

  settings {
    tier              = var.machine_type
    availability_type = var.availability_type
    disk_size         = var.disk_size
    ip_configuration {
      ipv4_enabled    = false
      private_network = var.service_networking_connection.network
    }

    backup_configuration {
      enabled    = var.backup_start_time == null ? false : true
      start_time = var.backup_start_time
    }

    user_labels = var.labels
  }

  deletion_protection = false
}

resource "random_string" "postgres_password" {
  length  = 20
  special = false
}

resource "google_sql_database" "tfe" {
  name     = var.dbname
  instance = google_sql_database_instance.tfe.name
}

resource "google_sql_user" "tfe" {
  name     = var.username
  instance = google_sql_database_instance.tfe.name

  deletion_policy = "ABANDON"
  password        = random_string.postgres_password.result
}
