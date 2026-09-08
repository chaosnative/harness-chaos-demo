# =============================================================================
# variables.tf — names and knobs for a single harness-resources apply
# =============================================================================
# Override any value with TF_VAR_<name>. Leave unset to keep workshop defaults.
#
# Terraform language in this folder is only main.tf + this file.
#
# What this root creates (one terraform apply):
#   1. Organization
#   2. Organization
#   3. One Harness project per namespace: banking-N → project team_N / team-N
#   4. Org-scoped delegate token + Kubernetes delegate on the EKS cluster
#   5. Per project: K8s connector, Prometheus, environment, infra, discovery, chaos v2
#   6. Per project: import chaos experiment from a hub template (if identities are set)
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

variable "create_organization" {
  description = "true = Terraform manages org workshop (create or update). false = look up only. Do NOT set false once the org is already in Terraform state — that plans a destroy of workshop. Org is prevent_destroy."
  type        = bool
  default     = true
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
  description = "Fixed extra wait after pods are Ready (Harness still marking CONNECTED). Prefer the poller; this is a small buffer after success."
  type        = string
  default     = "15s"
}

variable "delegate_helm_timeout" {
  description = "Helm wait timeout in seconds for the workshop delegate release."
  type        = number
  default     = 1200
}

variable "apply_retries" {
  description = "Retries for delegate-ready poll and chaos install_command. Pipeline should also re-run terraform apply on stage failure (do not destroy)."
  type        = number
  default     = 8

  validation {
    condition     = var.apply_retries >= 1 && var.apply_retries <= 30
    error_message = "apply_retries must be between 1 and 30."
  }
}

variable "apply_retry_interval" {
  description = "Seconds between retries."
  type        = number
  default     = 20

  validation {
    condition     = var.apply_retry_interval >= 5 && var.apply_retry_interval <= 120
    error_message = "apply_retry_interval must be between 5 and 120."
  }
}

# --- Per-project K8s connector; optional org AWS ---

variable "k8s_connector_id" {
  description = "Kubernetes connector identifier in each project (same id, different project). Empty = <resource_prefix>_eks. Infra refs this id (not org.<id>)."
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
  description = "Create one project-level Prometheus connector per team. URLs are http://prometheus.<namespace>.svc:9090 so they cannot be a single org connector."
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
  description = "CD infrastructure identifier and Chaos event-watcher Helm stem. Harness forbids hyphens; Helm forbids underscores. Empty = <resource_prefix without hyphens>k8s (hpbk8s)."
  type        = string
  default     = ""

  validation {
    condition     = var.infra_id == "" || can(regex("^[a-z][a-z0-9]{0,127}$", var.infra_id))
    error_message = "infra_id must be lowercase letters and digits only (no hyphen, no underscore) so it is valid for both Harness and Helm."
  }
}

variable "infra_name" {
  description = "Empty = infra_id"
  type        = string
  default     = ""
}

# --- Discovery / chaos ---

variable "discovery_agent_name_prefix" {
  description = "Name becomes <prefix>-<project name> (hpb-discovery-team-1). Empty = <resource_prefix>-discovery. Do not name the agent after the K8s namespace; PnC uses DA-banking-1 while the Namespace dropdown lists banking-1."
  type        = string
  default     = ""
}

variable "discovery_installation_type" {
  description = "CONNECTOR installs via the project's Kubernetes connector / delegate"
  type        = string
  default     = "CONNECTOR"
}

variable "discovery_install_namespace" {
  description = "Where collector pods run. Empty = delegate namespace (harness-delegate-ng), same as PnC. Inclusion still watches banking-N. Do not use hpb-sd-N."
  type        = string
  default     = ""
}

variable "discovery_service_account" {
  description = "Service account in the install namespace. PnC uses chaos-delegate. Must exist before the agent installs, or the collector never starts."
  type        = string
  default     = "chaos-delegate"
}

variable "create_discovery_service_account" {
  description = "true = Terraform creates the service account + cluster-admin binding in the delegate namespace. Set false if chaos-delegate already exists on hpb-eks (apply fails with already exists)."
  type        = bool
  default     = true
}

variable "discovery_cron_expression" {
  description = "Collector schedule. UI requires a minute step >= 15. PnC uses 0/15 * * * *. */10 is rejected and Last Discovery stays N/A."
  type        = string
  default     = "0/15 * * * *"

  validation {
    condition     = !can(regex("^[0*]/([0-9]|1[0-4]) ", var.discovery_cron_expression))
    error_message = "discovery_cron_expression minute step must be 15 or more (e.g. 0/15 * * * *). The Discovery form rejects anything smaller."
  }
}

variable "discovery_enable_network_trace" {
  description = "Detect network trace connectivity (node agent). PnC leaves this OFF for single-namespace Inclusion; on, the form also demands a node selector and duration. Only enable if you need connection maps."
  type        = bool
  default     = false
}

variable "discovery_node_agent_selector" {
  description = "Node selector for the network-trace node agent. Used only when discovery_enable_network_trace is true."
  type        = string
  default     = "kubernetes.io/os=linux"
}

variable "discovery_collection_window_in_min" {
  description = "Network-trace collection window. Used only when discovery_enable_network_trace is true. API max is 10."
  type        = number
  default     = 10

  validation {
    condition     = var.discovery_collection_window_in_min >= 1 && var.discovery_collection_window_in_min <= 10
    error_message = "discovery_collection_window_in_min must be between 1 and 10."
  }
}

variable "import_discovery_namespaces" {
  description = "Namespaces whose discovery agents already exist in Harness but not in state (partial create). Empty = create only. Pipeline retry after cron install failure: banking-1 and banking-2."
  type        = list(string)
  default     = []
}

variable "chaos_infra_name_prefix" {
  description = "Name becomes <prefix>-<project name> (hpb-chaos-team-1). Empty = <resource_prefix>-chaos"
  type        = string
  default     = ""
}

variable "chaos_infra_type" {
  description = "KUBERNETESV2 is DDCR (recommended). KUBERNETES is legacy V1. Provider values are uppercase."
  type        = string
  default     = "KUBERNETESV2"
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
  description = "Run chaos infra install_command via kubectl. CONNECTOR/DDCR returns null; leave false. true only if Harness returns a real shell command."
  type        = bool
  default     = false
}

# --- Experiment import (one template into every team project) ---

variable "experiment_hub_identity" {
  description = "Chaos hub in THIS account (workshop org or account-level). Example: org.workshop_chaos_hub. Empty = skip experiment import. Do not point at PnC."
  type        = string
  default     = ""
}

variable "experiment_template_identity" {
  description = "Identity of an experiment template that already exists in this account's hub. Empty = skip import."
  type        = string
  default     = ""
}

variable "experiment_template_revision" {
  type    = string
  default = "v1"
}

variable "experiment_import_type" {
  description = "LOCAL = independent copy per team. REFERENCE = stays linked to the template."
  type        = string
  default     = "LOCAL"

  validation {
    condition     = contains(["LOCAL", "REFERENCE"], var.experiment_import_type)
    error_message = "experiment_import_type must be LOCAL or REFERENCE."
  }
}

variable "experiment_name" {
  description = "Experiment display name. Empty = template identity."
  type        = string
  default     = ""
}

variable "experiment_hub_org_id" {
  description = "Org that owns the hub. Empty for account-level hubs; set to workshop for org-level hubs if hub_identity has no org. prefix."
  type        = string
  default     = ""
}

variable "experiment_hub_project_id" {
  description = "Project that owns the hub. Empty for account/org hubs."
  type        = string
  default     = ""
}
