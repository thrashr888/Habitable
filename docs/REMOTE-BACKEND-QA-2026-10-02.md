# Remote backend QA — 2026-10-02

The standalone Terraform CLI and Habitable both connected to an isolated HCP Terraform workspace in `pthrasher_v2`. The fixture has no providers or managed resources; the only state changes were output values.

The existing `terraform-fast` workspace (`ws-jwkDXaaPntEE485i`) was inspected read-only. It has auto-apply enabled, so no runs were started there.

## Isolated run evidence

- Workspace: `habitable-et3-20261002` (`ws-mkEiSkxUWoJeKbiN`), Terraform 1.6.6, remote execution, auto-apply disabled.
- Remote init succeeded using the Terraform CLI's default credentials configuration. `TF_CLI_CONFIG_FILE` was unset in this shell, so this run does not establish that the Habitable-only credentials file was the credential source; use `TF_CLI_CONFIG_FILE=~/.terraform.d/habitable.credentials.tfrc.json` when launching Terraform or Habitable for a scoped credential check.
- Plan `run-Q1o2uK8yjxXRCbsK` proposed only `backend_qa_value = "remote-output-loaded"`; HCP reported zero resources.
- Applying `/tmp/habitable-et3-20261002.tfplan` succeeded: 0 added, 0 changed, 0 destroyed.
- `terraform output -json` and `terraform state pull` both returned `backend_qa_value` with the expected string value; pulled state serial was 1.
- Follow-up plan `run-Hkz4vcT9Ckv1CSok` returned no changes (exit status 0).

## Habitable app QA

With `TF_CLI_CONFIG_FILE` set in the app's launch environment to the Habitable-only credentials file, Habitable loaded the remote state and showed the existing output. Run `run-mk7tgQHe6YkDeTsd` showed the output changing from `remote-output-loaded` to `remote-output-loaded-in-habitable`; confirming the saved plan applied successfully, the run reached Applied, and state contained one output. A following no-change run (`run-icLao3sNbTJB2dRe`) stayed Planned and did not offer confirmation under the no-op apply guard; the command text reported state up to date.

Starting and stopping the output stream for `run-BF6VzZeqrvidjmsP` returned the local UI to Ready with a canceled message explaining that the remote run might continue. The API later reported this run as `planned_and_finished`. An earlier no-change apply attempt (`run-n4irUWWkxdQUrCuP`) failed and exposed the missing no-op apply guard; the guard was added before the successful follow-up above. These runs made no resource changes.

The reusable minimal configuration is in [Tests/Fixtures/RemoteOutputsOnly/main.tf](../Tests/Fixtures/RemoteOutputsOnly/main.tf). Its dated workspace `habitable-et3-20261002` was removed after QA. To repeat this workflow, recreate the disposable workspace with remote execution and auto-apply disabled, then run the fixture from this directory. These observations used Terraform 1.6.6 in HCP.

All six listed runs were terminal (`applied` or `planned_and_finished`) before cleanup. Automatic approval review initially required direct authorization for irreversible remote workspace/state deletion. After the user explicitly authorized deleting Habitable test workspaces, the exact-ID delete succeeded on 2026-10-02. Subsequent lookups by workspace ID and organization/name returned Resource or path not found. No existing project workspace was deleted.

## Scope not covered

This verifies Terraform's real HCP backend path and Habitable's live output-only plan/apply flow. Workspace switching, cross-window stale-plan rejection, and provider/resource refresh behavior remain unverified. No production or existing fixture workspace was changed.
