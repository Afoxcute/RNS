# Provider Configuration
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.80.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Variables
variable "project_id" {
  description = "Google Cloud Project ID"
  type        = string
}

variable "region" {
  description = "Google Cloud Region"
  type        = string
  default     = "us-central1"
}

variable "service_name" {
  description = "Name of the service"
  type        = string
}

# Cloud SQL PostgreSQL Database
resource "google_sql_database_instance" "main" {
  name             = "${var.service_name}-postgres-instance"
  database_version = "POSTGRES_15"
  region           = var.region

  settings {
    tier = "db-f1-micro"  # Adjust based on your needs
    
    backup_configuration {
      enabled = true
      backup_retention_settings {
        retained_backups = 7
      }
    }

    ip_configuration {
      ipv4_enabled = true
      authorized_networks {
        name  = "allow-all"
        value = "0.0.0.0/0"
      }
    }
  }

  deletion_protection = true
}

resource "google_sql_database" "database" {
  name     = "${var.service_name}-database"
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "database_user" {
  name     = "${var.service_name}-dbuser"
  instance = google_sql_database_instance.main.name
  password = random_password.db_password.result
}

# Random Password for Database
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Cloud Run Service
resource "google_cloud_run_service" "main" {
  name     = var.service_name
  location = var.region

  template {
    spec {
      containers {
        image = var.service_image  # Replace with your container image

        env {
          name  = "DATABASE_URL"
          value = "postgresql://${google_sql_user.database_user.name}:${random_password.db_password.result}@${google_sql_database_instance.main.public_ip_address}/${google_sql_database.database.name}"
        }
        
        # Add additional environment variables as needed
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }
}

# Load Balancer with Cloud Run
resource "google_compute_global_address" "lb_ip" {
  name = "${var.service_name}-lb-ip"
}

resource "google_compute_backend_service" "backend" {
  name        = "${var.service_name}-backend"
  port_name   = "http"
  protocol    = "HTTP"
  timeout_sec = 30

  backend {
    group = google_cloud_run_service.main.status[0].url
  }
}

resource "google_compute_url_map" "urlmap" {
  name            = "${var.service_name}-urlmap"
  default_service = google_compute_backend_service.backend.id
}

resource "google_compute_target_http_proxy" "proxy" {
  name    = "${var.service_name}-proxy"
  url_map = google_compute_url_map.urlmap.id
}

resource "google_compute_global_forwarding_rule" "forwarding_rule" {
  name       = "${var.service_name}-forwarding-rule"
  target     = google_compute_target_http_proxy.proxy.id
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "80"
}

# Outputs
output "database_instance_connection_name" {
  value = google_sql_database_instance.main.connection_name
}

output "database_ip" {
  value = google_sql_database_instance.main.public_ip_address
}

output "cloud_run_url" {
  value = google_cloud_run_service.main.status[0].url
}

output "load_balancer_ip" {
  value = google_compute_global_address.lb_ip.address
}
