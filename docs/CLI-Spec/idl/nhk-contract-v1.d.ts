/** Human-readable IDL for the *proposed* CLI contract; machine validation is JSON Schema. */
export type CLIKind = "select" | "view" | "input" | "confirm" | "form";
export type InputFormat = "lines" | "text" | "csv" | "tsv" | "json" | "ndjson";
export type OutputFormat = "same" | "lines" | "csv" | "tsv" | "json" | "ndjson" | "values" | "result-json";
export type Theme = "system" | "dark" | "light";

export interface InputSpec {
  format: InputFormat;
  source: "stdin" | "file" | "none";
  file_path?: string;
}
export interface SelectionSpec {
  mode: "single" | "multiple";
  min?: number;
  max?: number;
  allow_empty?: boolean;
  value_field?: string;
  columns?: string[];
}
export interface UISpec {
  theme?: Theme;
  search?: string;
  page_size?: number;
}
export interface InvocationSpecV1 {
  schema_version: 1;
  kind: CLIKind;
  title?: string;
  input?: InputSpec;
  output?: { format: OutputFormat };
  selection?: SelectionSpec;
  ui?: UISpec;
  form_spec?: FormSpecV1;
}

export type FormFieldType = "text" | "textarea" | "number" | "checkbox" | "radio" | "select" | "multiselect" | "password";
export interface FormOption { value: string; label: string }
export interface FormField {
  id: string;
  type: FormFieldType;
  label: string;
  required?: boolean;
  sensitive?: boolean;
  default?: string | number | boolean | string[];
  min?: number;
  max?: number;
  step?: number;
  minlength?: number;
  maxlength?: number;
  pattern?: string;
  options?: FormOption[];
}
export interface FormSpecV1 {
  schema_version: 1;
  title: string;
  description?: string;
  fields: FormField[];
}

export interface SelectionResultV1 {
  schema_version: 1;
  kind: "select";
  status: "submitted";
  selected_indices: number[];
  selected: unknown[];
}
export interface FormResultV1 {
  schema_version: 1;
  kind: "form";
  status: "submitted";
  values: Record<string, unknown>;
}
export interface InputResultV1 {
  schema_version: 1;
  kind: "input";
  status: "submitted";
  value: string;
}
export interface ConfirmResultV1 {
  schema_version: 1;
  kind: "confirm";
  status: "submitted";
  accepted: true;
}
export type ResultEnvelopeV1 = SelectionResultV1 | FormResultV1 | InputResultV1 | ConfirmResultV1;

/** Private backend→launcher contract. Never stdout; never an MCP request. */
export type ReceiptV1 = {
  schema_version: 1;
  session_nonce: string;
  dataset_sha256: string;
  kind: CLIKind;
} & (
  | { status: "submitted"; selected_indices: number[] }
  | { status: "cancelled" }
);
