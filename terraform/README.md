# Terraform Infrastructure (optional self-hosted environments)

## Structure

```
terraform/
  modules/
    opensearch/     # OpenSearch cluster provisioning
    networking/     # VPC / VLAN abstraction
    certs/          # Certificate management via Vault
  environments/
    dev/
    staging/
    prod/
```

All modules use S3-compatible backend (MinIO for self-hosted).
