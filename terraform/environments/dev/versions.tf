# SURU — Dev environment version constraints (SEC-065)
# required_version lives here, separate from the backend block in main.tf, per
# the project layout standard. Terraform 1.6+ / OpenTofu 1.8+ compatible.
terraform {
  required_version = ">= 1.6"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.4"
    }
  }
}
