#!/bin/bash
# Creates a new, disposable local-only test workspace. Never overwrites a folder.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-/private/tmp/Habitable Playground}"
terraform_binary="${HABITABLE_TEST_TERRAFORM:-${HABITABLE_TERRAFORM_PATH:-}}"
if [[ -z "$terraform_binary" ]]; then terraform_binary="$(command -v terraform || true)"; fi
if [[ -z "$terraform_binary" || ! -x "$terraform_binary" ]]; then
  echo "Set HABITABLE_TEST_TERRAFORM to a Terraform executable (1.4 or newer)." >&2
  exit 1
fi
if [[ -e "$destination" ]]; then
  echo "Folder already exists; choose a new destination to preserve your edits: $destination" >&2
  exit 1
fi
mkdir -p "$destination"
cp -R "$repo_root/Tests/Fixtures/Playground/." "$destination/"
export TF_IN_AUTOMATION=1 TF_INPUT=0 TF_WORKSPACE=default

"$terraform_binary" -chdir="$destination" fmt -recursive > "$destination/setup-format.log"
"$terraform_binary" -chdir="$destination/state-source" init -no-color > "$destination/setup-state-init.log"
"$terraform_binary" -chdir="$destination/state-source" apply -auto-approve -no-color > "$destination/setup-state-apply.log"

# Only this newly created fixture is changed. Restore the review scenario even if seeding fails.
mv "$destination/migrations.tf" "$destination/.migrations.tf.disabled"
restore_scenario() {
  if [[ -f "$destination/.migrations.tf.disabled" ]]; then
    mv "$destination/.migrations.tf.disabled" "$destination/migrations.tf"
  fi
  rm -f "$destination/seed-only.tf"
}
trap restore_scenario EXIT
cat > "$destination/seed-only.tf" <<'HCL'
resource "terraform_data" "legacy" {
  input = { label = "A renamed local record" }
}
resource "terraform_data" "obsolete" {
  input = "This obsolete local record is removed in the review plan."
}
HCL
"$terraform_binary" -chdir="$destination" init -no-color > "$destination/setup-init.log"
"$terraform_binary" -chdir="$destination" apply -auto-approve -no-color \
  -var='scenario_generation=1' -var='enable_optional=true' > "$destination/setup-baseline.log"
restore_scenario
trap - EXIT

"$terraform_binary" -chdir="$destination" fmt -recursive > "$destination/setup-format.log"
"$terraform_binary" -chdir="$destination" validate -no-color > "$destination/setup-validate.log"
"$terraform_binary" -chdir="$destination" plan -input=false -no-color \
  -out=preview.tfplan > "$destination/preview.log"
"$terraform_binary" -chdir="$destination" show -json preview.tfplan > "$destination/preview.json"
"$terraform_binary" -chdir="$destination/Missing Inputs" init -no-color > "$destination/setup-missing-inputs.log"
"$terraform_binary" -chdir="$destination/Validation Errors" init -no-color > "$destination/setup-validation-errors.log"
echo "Playground created: $destination"
echo "Open the main folder in Habitable and queue a fresh plan. No mixed-change plan was applied."
