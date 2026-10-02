# Input, browsing, and diagnostic verification — 2026-10-02

This batch addresses Habitable-rt3.1 through rt3.6, plus rt3.18 found during live input-editor QA. Tests and live checks use Terraform 1.16.5. The universal Xcode Debug build passed; the combined core suite passed 83 tests with zero failures and one optional official-release-download check skipped.

## Input discovery and refresh

The local fixture at `/tmp/habitable-batch-20261002` has two built-in terraform_data resources, two outputs, and JSON tfvars containing a string with equals signs and a typed nested object. The app displayed both values correctly. A manually entered sensitive Terraform override and sensitive environment input could be saved through the native sheets. Their validation and secure-field controls updated immediately after the editor began observing its input model.

Refreshing preserved editor-created inputs and sensitivity metadata. Renaming the JSON tfvars file and refreshing removed its discovered entries while retaining the sensitive Terraform override. Regression tests also verify clearing both input lists on a directory switch and updating the optional tfvars presence check.

HCL discovery remains limited to simple single-line assignments. It preserves values containing equals signs and skips multiline expressions, heredocs, and block comments rather than presenting their inner lines as separate variables. Terraform continues interpreting the original files; this is not a complete HCL parser. Input persistence and edit/remove actions remain separate backlog work.

## Browsing and empty states

Native app checks selected beta then alpha resources; the detail address and name followed selection. Resource search for alpha hid beta. Searching for a nonexistent name showed No matching resources and removed stale detail selection. Output search for beta hid alpha; selecting beta and refreshing retained its selection and value.

Provider-free fixtures at `/tmp/habitable-batch-output-only`, `/tmp/habitable-batch-no-outputs`, and `/tmp/habitable-batch-empty` verified distinct No resources, No outputs, and neutral No state available messages. Loading and failure presentations use existing command/error state and remain compatible with macOS 13.

## Diagnostics

A real plan with an invalid variable validation rule produced an Errored run. Its diagnostic displayed the source filename, line 1, the underlined offending snippet, and the explanatory text. Error and warning presentations have distinct labels and symbols.

The renderer uses UTF-8 byte offsets observed in a real Terraform 1.16.5 diagnostic with an emoji before the error. HashiCorp's [validate JSON documentation](https://developer.hashicorp.com/terraform/cli/commands/validate#json-output-format) calls these character offsets, while the tested CLI reports bytes. Regression tests cover that actual snippet, correct snippet start-line parsing, invalid boundaries, out-of-range offsets, and multiline source. Invalid offsets leave readable, unhighlighted source. Existing sensitive-value redaction is unchanged.
