# SURU — Dev environment
#
# State encryption (SEC-065): this backend gives transport encryption (HTTPS to
# MinIO) plus whatever server-side encryption MinIO is configured for — but NOT
# native Terraform state-at-rest encryption. The `terraform { encryption {} }`
# block (KMS or PBKDF2 key provider) is an OpenTofu 1.7+ feature and is NOT
# available in Terraform CE, so adding it here would break `terraform validate`.
# To encrypt state at rest, migrate this environment to OpenTofu 1.8+ and add an
# encryption block; until then rely on MinIO SSE + restricted bucket access.
terraform {
  backend "s3" {
    bucket = "suru-terraform-state"
    key    = "dev/terraform.tfstate"
    region = "us-east-1" # Adjust for MinIO
    # HTTPS endpoint (SEC-065 — was plaintext http://). Uses the modern
    # `endpoints`/`use_path_style` form; the singular `endpoint`/`force_path_style`
    # args are deprecated in the Terraform 1.6+ s3 backend.
    endpoints = {
      s3 = "https://minio.suru.internal:9000"
    }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    # MinIO is not AWS — without this, the s3 backend tries to resolve an AWS
    # account ID (IAM/STS) at init and fails unless real AWS creds are present.
    skip_requesting_account_id = true
  }
}

module "networking" {
  source = "../../modules/networking"
  env    = "dev"
  subnet = "172.28.0.0/24"
}
