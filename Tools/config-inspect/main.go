package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/hashicorp/terraform-config-inspect/tfconfig"
	"github.com/zclconf/go-cty/cty"
	ctyjson "github.com/zclconf/go-cty/cty/json"
)

type inputOutput struct {
	Path        string                    `json:"path"`
	Variables   map[string]variableOutput `json:"variables"`
	Diagnostics tfconfig.Diagnostics      `json:"diagnostics,omitempty"`
}

type metadataOutput struct {
	Path              string                              `json:"path"`
	Variables         map[string]variableMetadataOutput   `json:"variables"`
	Outputs           map[string]outputMetadataOutput     `json:"outputs"`
	RequiredProviders map[string]providerMetadataOutput   `json:"required_providers"`
	ModuleCalls       map[string]moduleCallMetadataOutput `json:"module_calls"`
	Resources         map[string]resourceMetadataOutput   `json:"resources"`
	RequiredCore      []string                            `json:"required_core,omitempty"`
	Backend           *backendMetadataOutput              `json:"backend,omitempty"`
	Diagnostics       tfconfig.Diagnostics                `json:"diagnostics,omitempty"`
}

type backendMetadataOutput struct {
	Type         string                   `json:"type"`
	Hostname     string                   `json:"hostname,omitempty"`
	Organization string                   `json:"organization,omitempty"`
	Workspaces   *backendWorkspacesOutput `json:"workspaces,omitempty"`
	Unresolved   []string                 `json:"unresolved,omitempty"`
	Pos          tfconfig.SourcePos       `json:"pos"`
}

type backendWorkspacesOutput struct {
	Name    string   `json:"name,omitempty"`
	Tags    []string `json:"tags,omitempty"`
	Prefix  string   `json:"prefix,omitempty"`
	Project string   `json:"project,omitempty"`
}

type resourceMetadataOutput struct {
	Address string             `json:"address"`
	Pos     tfconfig.SourcePos `json:"pos"`
}

type variableMetadataOutput struct {
	Name        string             `json:"name"`
	Type        string             `json:"type,omitempty"`
	Description string             `json:"description,omitempty"`
	Required    bool               `json:"required"`
	HasDefault  bool               `json:"has_default"`
	Sensitive   bool               `json:"sensitive,omitempty"`
	Ephemeral   bool               `json:"ephemeral"`
	Pos         tfconfig.SourcePos `json:"pos"`
}

type providerMetadataOutput struct {
	Name               string                 `json:"name"`
	Source             string                 `json:"source,omitempty"`
	VersionConstraints []string               `json:"version_constraints,omitempty"`
	Aliases            []tfconfig.ProviderRef `json:"aliases,omitempty"`
}

type moduleCallMetadataOutput struct {
	Name    string             `json:"name"`
	Source  string             `json:"source"`
	Version string             `json:"version,omitempty"`
	Pos     tfconfig.SourcePos `json:"pos"`
}

type outputMetadataOutput struct {
	Name        string             `json:"name"`
	Description string             `json:"description,omitempty"`
	Sensitive   bool               `json:"sensitive,omitempty"`
	Type        string             `json:"type,omitempty"`
	Pos         tfconfig.SourcePos `json:"pos"`
}

type variableOutput struct {
	Name        string             `json:"name"`
	Type        string             `json:"type,omitempty"`
	Description string             `json:"description,omitempty"`
	Default     any                `json:"default"`
	Required    bool               `json:"required"`
	HasDefault  bool               `json:"has_default"`
	Sensitive   bool               `json:"sensitive,omitempty"`
	Ephemeral   bool               `json:"ephemeral"`
	Pos         tfconfig.SourcePos `json:"pos"`
}

type valueOutput struct {
	Values      map[string]json.RawMessage `json:"values"`
	Unresolved  []string                   `json:"unresolved,omitempty"`
	Diagnostics []string                   `json:"diagnostics,omitempty"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: habitable-config inspect|tfvars DIRECTORY_OR_FILE")
		os.Exit(2)
	}
	var result any
	var err error
	switch os.Args[1] {
	case "inspect":
		if len(os.Args) != 3 {
			err = fmt.Errorf("usage: habitable-config inspect DIRECTORY")
			break
		}
		result, err = inspect(os.Args[2])
	case "metadata":
		if len(os.Args) != 3 {
			err = fmt.Errorf("usage: habitable-config-inspect metadata DIRECTORY")
			break
		}
		result, err = inspectMetadata(os.Args[2])
	case "tfvars":
		if len(os.Args) != 3 {
			err = fmt.Errorf("usage: habitable-config tfvars FILE")
			break
		}
		result, err = readValues(os.Args[2])
	case "tfvar":
		if len(os.Args) != 3 {
			err = fmt.Errorf("usage: habitable-config-inspect tfvar NAME < value via stdin")
		} else {
			var value []byte
			value, err = io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
			if err == nil {
				result, err = readEnvironmentValue(os.Args[2], string(value))
			}
		}
	default:
		err = fmt.Errorf("unknown operation %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func readEnvironmentValue(name, raw string) (map[string]json.RawMessage, error) {
	value, diagnostics := hclsyntax.ParseExpression([]byte(raw), "TF_VAR_"+name, hcl.Pos{Line: 1, Column: 1})
	if !diagnostics.HasErrors() {
		converted, valueDiagnostics := value.Value(nil)
		if !valueDiagnostics.HasErrors() && converted.IsWhollyKnown() {
			encoded, err := ctyjson.Marshal(converted, converted.Type())
			if err == nil {
				return map[string]json.RawMessage{name: encoded}, nil
			}
		}
	}
	encoded, err := json.Marshal(raw)
	if err != nil {
		return nil, err
	}
	return map[string]json.RawMessage{name: encoded}, nil
}

func inspect(directory string) (*inputOutput, error) {
	module, diagnostics := tfconfig.LoadModule(directory)
	if module == nil {
		return nil, fmt.Errorf("HashiCorp config-inspect could not read %s", directory)
	}
	properties, propDiagnostics := readDeclarationProperties(directory)
	variables := make(map[string]variableOutput, len(module.Variables))
	for name, item := range module.Variables {
		props := properties[name]
		hasDefault := props.hasDefault || !item.Required
		variables[name] = variableOutput{Name: item.Name, Type: item.Type, Description: item.Description,
			Default: item.Default, Required: !hasDefault, HasDefault: hasDefault,
			Sensitive: item.Sensitive, Ephemeral: props.ephemeral, Pos: item.Pos}
	}
	diagnostics = append(diagnostics, propDiagnostics...)
	return &inputOutput{Path: module.Path, Variables: variables, Diagnostics: diagnostics}, nil
}

func inspectMetadata(directory string) (*metadataOutput, error) {
	module, diagnostics := tfconfig.LoadModule(directory)
	if module == nil {
		return nil, fmt.Errorf("HashiCorp config-inspect could not read module metadata")
	}
	properties, propDiagnostics := readDeclarationProperties(directory)
	variables := make(map[string]variableMetadataOutput, len(module.Variables))
	for name, item := range module.Variables {
		props := properties[name]
		hasDefault := props.hasDefault || !item.Required
		variables[name] = variableMetadataOutput{Name: item.Name, Type: item.Type, Description: item.Description,
			Required: !hasDefault, HasDefault: hasDefault, Sensitive: item.Sensitive, Ephemeral: props.ephemeral, Pos: item.Pos}
	}
	outputs := make(map[string]outputMetadataOutput, len(module.Outputs))
	for name, item := range module.Outputs {
		outputs[name] = outputMetadataOutput{Name: item.Name, Description: item.Description, Sensitive: item.Sensitive, Type: item.Type, Pos: item.Pos}
	}
	providers := make(map[string]providerMetadataOutput, len(module.RequiredProviders))
	for name, item := range module.RequiredProviders {
		providers[name] = providerMetadataOutput{Name: name, Source: item.Source, VersionConstraints: item.VersionConstraints, Aliases: item.ConfigurationAliases}
	}
	moduleCalls := make(map[string]moduleCallMetadataOutput, len(module.ModuleCalls))
	for name, item := range module.ModuleCalls {
		moduleCalls[name] = moduleCallMetadataOutput{Name: item.Name, Source: item.Source, Version: item.Version, Pos: item.Pos}
	}
	resources := make(map[string]resourceMetadataOutput, len(module.ManagedResources)+len(module.DataResources))
	for _, item := range module.ManagedResources {
		address := item.MapKey()
		resources[address] = resourceMetadataOutput{Address: address, Pos: item.Pos}
	}
	for _, item := range module.DataResources {
		address := item.MapKey()
		resources[address] = resourceMetadataOutput{Address: address, Pos: item.Pos}
	}
	diagnostics = append(diagnostics, propDiagnostics...)
	backend, backendDiagnostics := readBackend(directory)
	diagnostics = append(diagnostics, backendDiagnostics...)
	return &metadataOutput{Path: module.Path, Variables: variables, Outputs: outputs,
		RequiredProviders: providers, ModuleCalls: moduleCalls, Resources: resources, RequiredCore: module.RequiredCore, Backend: backend, Diagnostics: diagnostics}, nil
}

func readValues(filename string) (*valueOutput, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return nil, err
	}
	out := &valueOutput{Values: map[string]json.RawMessage{}}
	if filepath.Ext(filename) == ".json" {
		var values map[string]json.RawMessage
		if err := json.Unmarshal(data, &values); err != nil {
			return nil, err
		}
		out.Values = values
		return out, nil
	}
	file, diags := hclsyntaxParse(filename, data)
	if diags.HasErrors() {
		return nil, fmt.Errorf("%s", diags.Error())
	}
	attrs, diags := file.Body.JustAttributes()
	if diags.HasErrors() {
		return nil, fmt.Errorf("%s", diags.Error())
	}
	for key, attr := range attrs {
		value, valueDiags := attr.Expr.Value(nil)
		if valueDiags.HasErrors() || !value.IsWhollyKnown() {
			out.Unresolved = append(out.Unresolved, key)
			out.Diagnostics = append(out.Diagnostics, fmt.Sprintf("%s: value for %s is an expression that cannot be resolved without Terraform", filename, key))
			continue
		}
		if value.IsNull() {
			out.Values[key] = json.RawMessage("null")
			continue
		}
		encoded, err := ctyjson.Marshal(value, value.Type())
		if err != nil {
			out.Diagnostics = append(out.Diagnostics, fmt.Sprintf("%s: value for %s cannot be represented as JSON", filename, key))
			continue
		}
		out.Values[key] = encoded
	}
	return out, nil
}

type declarationProperties struct {
	hasDefault bool
	ephemeral  bool
}

func readDeclarationProperties(directory string) (map[string]declarationProperties, tfconfig.Diagnostics) {
	properties := map[string]declarationProperties{}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return properties, tfconfig.Diagnostics{{Severity: tfconfig.DiagError, Summary: "Could not list configuration files", Detail: err.Error()}}
	}
	var diagnostics tfconfig.Diagnostics
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if filepath.Ext(name) == ".tf" {
			data, err := os.ReadFile(filepath.Join(directory, name))
			if err != nil {
				continue
			}
			file, diags := hclsyntax.ParseConfig(data, name, hcl.Pos{Line: 1, Column: 1})
			if diags.HasErrors() {
				diagnostics = append(diagnostics, tfconfig.Diagnostic{Severity: tfconfig.DiagError, Summary: "Could not inspect variable declaration metadata", Detail: diags.Error()})
				continue
			}
			for _, block := range file.Body.(*hclsyntax.Body).Blocks {
				if block.Type != "variable" || len(block.Labels) != 1 {
					continue
				}
				prop := properties[block.Labels[0]]
				if _, ok := block.Body.Attributes["default"]; ok {
					prop.hasDefault = true
				}
				if attr, ok := block.Body.Attributes["ephemeral"]; ok {
					value, valueDiags := attr.Expr.Value(nil)
					if !valueDiags.HasErrors() && value.IsKnown() && !value.IsNull() && value.Type() == cty.Bool && value.True() {
						prop.ephemeral = true
					}
				}
				properties[block.Labels[0]] = prop
			}
		} else if strings.HasSuffix(name, ".tf.json") {
			data, err := os.ReadFile(filepath.Join(directory, name))
			if err != nil {
				continue
			}
			var root map[string]json.RawMessage
			if err := json.Unmarshal(data, &root); err != nil {
				continue
			}
			var declarations map[string]map[string]json.RawMessage
			if err := json.Unmarshal(root["variable"], &declarations); err != nil {
				continue
			}
			for key, attributes := range declarations {
				var ephemeral bool
				if raw := attributes["ephemeral"]; len(raw) > 0 {
					_ = json.Unmarshal(raw, &ephemeral)
				}
				properties[key] = declarationProperties{hasDefault: len(attributes["default"]) > 0, ephemeral: ephemeral}
			}
		}
	}
	return properties, diagnostics
}

// Kept separate to make parser diagnostics visible at the input boundary.
func hclsyntaxParse(filename string, data []byte) (*hcl.File, hcl.Diagnostics) {
	return hclsyntax.ParseConfig(data, filename, hcl.Pos{Line: 1, Column: 1})
}

// readBackend finds the first terraform { cloud {} } or backend "X" {} declaration
// in the directory's *.tf files, reading only literal values.
func readBackend(directory string) (*backendMetadataOutput, tfconfig.Diagnostics) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, nil
	}
	var found []*backendMetadataOutput
	for _, entry := range entries { // ReadDir returns entries sorted by filename.
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".tf" {
			continue
		}
		path := filepath.Join(directory, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		file, diags := hclsyntaxParse(entry.Name(), data)
		if diags.HasErrors() {
			continue
		}
		body, ok := file.Body.(*hclsyntax.Body)
		if !ok {
			continue
		}
		for _, block := range body.Blocks {
			if block.Type != "terraform" {
				continue
			}
			for _, nested := range block.Body.Blocks {
				isCloud := nested.Type == "cloud" && len(nested.Labels) == 0
				isBackend := nested.Type == "backend" && len(nested.Labels) == 1
				if !isCloud && !isBackend {
					continue
				}
				out := &backendMetadataOutput{Type: "cloud", Pos: tfconfig.SourcePos{Filename: path, Line: nested.DefRange().Start.Line}}
				if isBackend {
					out.Type = nested.Labels[0]
				}
				if isCloud || out.Type == "remote" {
					readRemoteBackend(nested.Body, out)
				}
				found = append(found, out)
			}
		}
	}
	if len(found) == 0 {
		return nil, nil
	}
	var diagnostics tfconfig.Diagnostics
	if len(found) > 1 {
		diagnostics = append(diagnostics, tfconfig.Diagnostic{Severity: tfconfig.DiagWarning, Summary: "Multiple backend declarations",
			Detail: fmt.Sprintf("Found %d backend or cloud declarations; using the first, at %s:%d.", len(found), found[0].Pos.Filename, found[0].Pos.Line)})
	}
	return found[0], diagnostics
}

func literalValue(attr *hclsyntax.Attribute) (cty.Value, bool) {
	if len(attr.Expr.Variables()) != 0 {
		return cty.NilVal, false
	}
	value, diags := attr.Expr.Value(nil)
	if diags.HasErrors() || !value.IsWhollyKnown() || value.IsNull() {
		return cty.NilVal, false
	}
	return value, true
}

func literalString(attr *hclsyntax.Attribute) (string, bool) {
	value, ok := literalValue(attr)
	if !ok || value.Type() != cty.String {
		return "", false
	}
	return value.AsString(), true
}

func literalStringList(attr *hclsyntax.Attribute) ([]string, bool) {
	value, ok := literalValue(attr)
	if !ok {
		return nil, false
	}
	ty := value.Type()
	if !ty.IsListType() && !ty.IsTupleType() && !ty.IsSetType() {
		return nil, false
	}
	var items []string
	for it := value.ElementIterator(); it.Next(); {
		_, element := it.Element()
		if element.IsNull() || element.Type() != cty.String {
			return nil, false
		}
		items = append(items, element.AsString())
	}
	return items, true
}

func readRemoteBackend(body *hclsyntax.Body, out *backendMetadataOutput) {
	setString := func(attrs hclsyntax.Attributes, key, path string, dest *string) {
		attr, ok := attrs[key]
		if !ok {
			return
		}
		if value, ok := literalString(attr); ok {
			*dest = value
		} else {
			out.Unresolved = append(out.Unresolved, path)
		}
	}
	setString(body.Attributes, "hostname", "hostname", &out.Hostname)
	setString(body.Attributes, "organization", "organization", &out.Organization)
	for _, nested := range body.Blocks {
		if nested.Type != "workspaces" || len(nested.Labels) != 0 {
			continue
		}
		ws := &backendWorkspacesOutput{}
		out.Workspaces = ws
		setString(nested.Body.Attributes, "name", "workspaces.name", &ws.Name)
		setString(nested.Body.Attributes, "prefix", "workspaces.prefix", &ws.Prefix)
		setString(nested.Body.Attributes, "project", "workspaces.project", &ws.Project)
		if attr, ok := nested.Body.Attributes["tags"]; ok {
			if tags, ok := literalStringList(attr); ok {
				ws.Tags = tags
			} else {
				out.Unresolved = append(out.Unresolved, "workspaces.tags")
			}
		}
		break
	}
}
