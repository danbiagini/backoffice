# Partial backend config — bucket/prefix come from `backend.hcl` (gitignored).
# Init with:  tofu init -backend-config=backend.hcl
# See backend.hcl.example for the expected shape.
terraform {
  backend "gcs" {}
}
