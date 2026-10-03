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
	Diagnostics       tfconfig.Diagnostics                `json:"diagnostics,omitempty"`
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
	return &metadataOutput{Path: module.Path, Variables: variables, Outputs: outputs,
		RequiredProviders: providers, ModuleCalls: moduleCalls, Resources: resources, RequiredCore: module.RequiredCore, Diagnostics: diagnostics}, nil
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
