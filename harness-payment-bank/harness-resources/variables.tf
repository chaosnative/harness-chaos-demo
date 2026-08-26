# =============================================================================
# variables.tf — names and knobs for a single harness-resources apply
# =============================================================================
# Override any value with TF_VAR_<name>. Leave unset to keep workshop defaults.
#
# What this root creates (one terraform apply):
#   1. Organization
#   2. Org Connector templates (K8s inherit-from-delegate, AWS inherit-from-delegate, Prometheus)
#   3. One Harness project per namespace: banking-N → project team_N / team-N
#   4. Org-scoped delegate token + Kubernetes delegate on the EKS cluster
#   5. Org AWS connector (optional); per-project K8s + Prometheus connectors
#   6. Per project: environment, Kubernetes infra def, discovery agent, chaos infra v2
#
# PAT (HARNESS_PLATFORM_API_KEY) must be issued in the same account as account_id.
#
# Prerequisites: infrastructure/ already applied; HARNESS_ACCOUNT_ID,
# HARNESS_PLATFORM_API_KEY, TF_VAR_account_id, aws, helm, kubectl.

# --- Harness account / API ---

variable "account_id" {
  description = "Harness account ID where org workshop is created. Must match the account that issued HARNESS_PLATFORM_API_KEY. Export TF_VAR_account_id."
  type        = string
}

variable "harness_gateway_endpoint" {
  description = "Harness NG API gateway (provider). Not the delegate manager URL."
  type        = string
  default     = "https://app.harness.io/gateway"
}

variable "manager_endpoint" {
  description = "Delegate manager URL. Copy from Account Settings → Overview if the default is wrong."
  type        = string
  default     = "https://app.harness.io"
}

# --- Shared naming ---

variable "resource_prefix" {
  description = "Prefix baked into generated connector, delegate, discovery, and chaos names when those variables are left empty."
  type        = string
  default     = "hpb"
}

variable "tags" {
  description = "Harness tags as key:value strings"
  type        = list(string)
  default     = ["workshop:true", "project:hpb", "managedby:terraform"]
}

# --- Organization ---

variable "org_id" {
  description = "Organization identifier"
  type        = string
  default     = "workshop"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.org_id))
    error_message = "org_id must start with a letter and contain only letters, digits, and underscores."
  }
}

variable "org_name" {
  description = "Organization display name. Empty = use org_id."
  type        = string
  default     = ""
}

variable "org_description" {
  type    = string
  default = "Chaos engineering workshop organization for Harness Payment Bank"
}

# --- Target cluster / namespaces ---

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Empty = infrastructure remote-state output cluster_name."
  type        = string
  default     = ""
}

variable "namespaces" {
  description = "Kubernetes namespaces / workshop projects. Empty = infrastructure remote-state output namespaces."
  type        = list(string)
  default     = []
}

variable "namespace_prefix" {
  description = "Used only if namespaces is empty and infrastructure state has no namespaces output"
  type        = string
  default     = "banking"
}

variable "namespace_count" {
  type    = number
  default = 4

  validation {
    condition     = var.namespace_count >= 1 && var.namespace_count <= 8
    error_message = "namespace_count must be between 1 and 8."
  }
}

# --- Projects (one per namespace) ---

variable "project_identifier_prefix" {
  description = "Harness project identifier is <prefix>_<index>. Default team → team_1 for namespace banking-1."
  type        = string
  default     = "team"
}

variable "project_name_prefix" {
  description = "Harness project display name is <prefix>-<index>. Default team → team-1 for namespace banking-1."
  type        = string
  default     = "team"
}

variable "project_color" {
  type    = string
  default = "#0063F7"
}

variable "project_overrides" {
  description = "Per-namespace project identifier/name. Keys must match Kubernetes namespace names."
  type = map(object({
    identifier = optional(string)
    name       = optional(string)
  }))
  default = {}
}

# --- Connector templates (org, created in the same apply) ---

variable "create_connector_templates" {
  description = "Create org Connector templates. Set false if they already exist in the org and should only be looked up."
  type        = bool
  default     = true
}

variable "template_version" {
  type    = string
  default = "v1"
}

variable "k8s_template_id" {
  description = "Empty = <resource_prefix>_k8s_inherit_delegate"
  type        = string
  default     = ""
}

variable "k8s_template_name" {
  description = "Empty = k8s_template_id"
  type        = string
  default     = ""
}

variable "aws_template_id" {
  description = "Empty = <resource_prefix>_aws_inherit_delegate"
  type        = string
  default     = ""
}

variable "aws_template_name" {
  description = "Empty = aws_template_id"
  type        = string
  default     = ""
}

variable "prometheus_template_id" {
  description = "Empty = <resource_prefix>_prometheus"
  type        = string
  default     = ""
}

variable "prometheus_template_name" {
  description = "Empty = prometheus_template_id"
  type        = string
  default     = ""
}

# --- Delegate ---

variable "delegate_name" {
  description = "Delegate name and selector. Empty = <resource_prefix>-workshop-delegate"
  type        = string
  default     = ""
}

variable "delegate_namespace" {
  type    = string
  default = "harness-delegate-ng"
}

variable "delegate_token_name" {
  description = "Empty = <resource_prefix>-workshop-delegate-token"
  type        = string
  default     = ""
}

variable "delegate_replicas" {
  type    = number
  default = 1
}

variable "decode_delegate_token" {
  description = "Provider returns the token base64-encoded. Set false only if helm registration fails."
  type        = bool
  default     = true
}

variable "delegate_register_wait" {
  description = "Wait after helm Ready so Harness can mark the delegate CONNECTED before connectors are created."
  type        = string
  default     = "60s"
}

# --- Org connectors ---

variable "k8s_connector_id" {
  description = "Same identifier in every project (not org-level). Empty = <resource_prefix>_eks. Infra refs this id in the project."
  type        = string
  default     = ""
}

variable "k8s_connector_name" {
  description = "Empty = k8s_connector_id"
  type        = string
  default     = ""
}

variable "create_aws_connector" {
  type    = bool
  default = true
}

variable "aws_connector_id" {
  description = "Empty = <resource_prefix>_aws"
  type        = string
  default     = ""
}

variable "aws_connector_name" {
  description = "Empty = aws_connector_id"
  type        = string
  default     = ""
}

variable "create_prometheus_connectors" {
  description = "Create one project-level Prometheus connector per team (in-cluster URL for banking-N)."
  type        = bool
  default     = true
}

variable "prometheus_connector_id_prefix" {
  description = "Identifier becomes <prefix>_<project_id> (e.g. hpb_prometheus_team_1). Empty = <resource_prefix>_prometheus"
  type        = string
  default     = ""
}

variable "prometheus_connector_name_prefix" {
  description = "Display name becomes <prefix>-<project_name> (e.g. hpb-prometheus-team-1). Empty = <resource_prefix>-prometheus"
  type        = string
  default     = ""
}

variable "prometheus_port" {
  type    = number
  default = 9090
}

# --- Per-project environment / infra ---

variable "environment_id" {
  description = "Empty = resource_prefix"
  type        = string
  default     = ""
}

variable "environment_name" {
  description = "Empty = environment_id"
  type        = string
  default     = ""
}

variable "environment_type" {
  type    = string
  default = "PreProduction"

  validation {
    condition     = contains(["PreProduction", "Production"], var.environment_type)
    error_message = "environment_type must be PreProduction or Production."
  }
}

variable "infra_id" {
  description = "Empty = <resource_prefix>_k8s"
  type        = string
  default     = ""
}

variable "infra_name" {
  description = "Empty = infra_id"
  type        = string
  default     = ""
}

# --- Discovery / chaos ---

variable "discovery_agent_name_prefix" {
  description = "Name becomes <prefix>-<project name> (hpb-discovery-team-1). Empty = <resource_prefix>-discovery"
  type        = string
  default     = ""
}

variable "discovery_installation_type" {
  description = "CONNECTOR installs via the project's Kubernetes connector / delegate"
  type        = string
  default     = "CONNECTOR"
}

variable "discovery_install_namespace" {
  description = "Namespace for the discovery agent pods. Empty = the project's app namespace."
  type        = string
  default     = ""
}

variable "chaos_infra_name_prefix" {
  description = "Name becomes <prefix>-<project name> (hpb-chaos-team-1). Empty = <resource_prefix>-chaos"
  type        = string
  default     = ""
}

variable "chaos_infra_type" {
  description = "KubernetesV2 is DDCR (recommended). Kubernetes is legacy V1."
  type        = string
  default     = "KubernetesV2"
}

variable "chaos_infra_scope" {
  type    = string
  default = "NAMESPACE"

  validation {
    condition     = contains(["NAMESPACE", "CLUSTER"], var.chaos_infra_scope)
    error_message = "chaos_infra_scope must be NAMESPACE or CLUSTER."
  }
}

variable "chaos_service_account" {
  type    = string
  default = "harness-chaos"
}

variable "ai_enabled" {
  type    = bool
  default = true
}

variable "apply_chaos_install_command" {
  description = "Run any install_command Harness returns after registering chaos infra v2."
  type        = bool
  default     = true
}
