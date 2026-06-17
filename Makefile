.PHONY: sops-unlock sops-edit sops-decrypt

# Print instructions for loading the age key into your current shell.
# Exports set inside a make recipe cannot propagate to the parent shell;
# run the source command directly in your terminal instead.
sops-unlock:
	@echo "To load the SOPS age key into your current shell, run:"
	@echo "  source tier4-operations/scripts/sops-unlock.sh"

# Usage: make sops-edit FILE=path/to/secrets.enc.yaml
sops-edit:
	@bash -c 'source "$(CURDIR)/tier4-operations/scripts/sops-unlock.sh" && sops "$(FILE)"'

# Usage: make sops-decrypt FILE=path/to/secrets.enc.yaml
sops-decrypt:
	@bash -c 'source "$(CURDIR)/tier4-operations/scripts/sops-unlock.sh" && sops -d "$(FILE)"'
