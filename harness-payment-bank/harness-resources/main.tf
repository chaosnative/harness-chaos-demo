# =============================================================================
# main.tf — org workshop → templates → team projects → delegate → connectors
# =============================================================================
# Single Terraform root. Only this file and variables.tf are Terraform language.
#
# Order:
#   1. Read infrastructure remote state (cluster + banking-N) unless overridden
#   2. Organization workshop
#   3. Org experiment templates on existing custom-hub-workshop (gated; no new hub)
#   4. Projects team-N (one per namespace banking-N)
#   5. Org delegate token + Helm on EKS; wait for registration
#   6. Optional org AWS connector
#   7. Per project: K8s connector, Prometheus, environment, infra, discovery,
#      chaos v2, experiment import from a chaos hub template (if ids are set)
#
# Connector "templates" are not created here. Harness NG template types do not
# include Connector (only Step, Stage, Pipeline, …). Connectors are created
# with harness_platform_connector_* (InheritFromDelegate).
# Chaos experiment templates live on the existing org hub custom-hub-workshop
# (data.harness_chaos_hub_v2). Identities match PnC / the live hub so apply
# updates in place. Do not create a second hub.
#
# Failure / retry: do not terraform destroy this root on error. Re-run apply.
# Resources already in state are left alone; missing ones are created.
# Harness TerraformApply runs `terraform refresh` as its own command.
# TF_CLI_ARGS_apply does not skip that. On TerraformApply_2 enable
# "Skip Refresh Command" (skipRefreshCommand: true) until this apply succeeds.
# Helm is non-atomic so a timed-out delegate is upgraded in place on retry.
# upgrade_install adopts a cluster release that is not in Terraform state
# (previous apply installed Helm, then failed before state was saved).
# CD infra identifier is used as Helm release stem event-watcher-<infra_id>.
# Harness IDs forbid hyphens; Helm forbids underscores. Use lowercase
# alphanumeric only (e.g. hpbk8s).
#
# Docs:
#   https://registry.terraform.io/providers/harness/harness/latest/docs
#   https://developer.harness.io/docs/resilience-testing/platform-features/terraform-onboarding

terraform {
  required_version = ">= 1.8.0"

  backend "s3" {
    bucket         = "hpb-demo-tfstate-naren"
    key            = "hpb-harness/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "hpb-demo-tf-lock"
  }

  required_providers {
    harness = {
      source  = "harness/harness"
      version = "~> 0.45"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# PAT (HARNESS_PLATFORM_API_KEY) must be issued in this same account.
provider "harness" {
  endpoint   = var.harness_gateway_endpoint
  account_id = var.account_id
}

provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", data.aws_eks_cluster.this.name,
      "--region", var.aws_region,
    ]
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", data.aws_eks_cluster.this.name,
        "--region", var.aws_region,
      ]
    }
  }
}

locals {
  infra_state_needed = var.cluster_name == "" || length(var.namespaces) == 0
}

data "terraform_remote_state" "infra" {
  count = local.infra_state_needed ? 1 : 0

  backend = "s3"
  config = {
    bucket = "hpb-demo-tfstate-naren"
    key    = "hpb-eks/terraform.tfstate"
    region = "us-east-1"
  }
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

locals {
  prefix_id = replace(var.resource_prefix, "-", "_")
  org_id    = var.org_id
  org_name  = var.org_name != "" ? var.org_name : var.org_id
  tags      = var.tags

  generated_namespaces = [for i in range(1, var.namespace_count + 1) : "${var.namespace_prefix}-${i}"]
  namespaces = length(var.namespaces) > 0 ? var.namespaces : coalesce(
    try(data.terraform_remote_state.infra[0].outputs.namespaces, null),
    local.generated_namespaces,
  )
  cluster_name = var.cluster_name != "" ? var.cluster_name : data.terraform_remote_state.infra[0].outputs.cluster_name

  delegate_name       = var.delegate_name != "" ? var.delegate_name : "${var.resource_prefix}-workshop-delegate"
  delegate_token_name = var.delegate_token_name != "" ? var.delegate_token_name : "${var.resource_prefix}-workshop-delegate-token"
  delegate_token      = var.decode_delegate_token ? base64decode(harness_platform_delegatetoken.this.value) : harness_platform_delegatetoken.this.value

  k8s_connector_id       = var.k8s_connector_id != "" ? var.k8s_connector_id : "${local.prefix_id}_eks"
  k8s_connector_name     = var.k8s_connector_name != "" ? var.k8s_connector_name : local.k8s_connector_id
  aws_connector_id       = var.aws_connector_id != "" ? var.aws_connector_id : "${local.prefix_id}_aws"
  aws_connector_name     = var.aws_connector_name != "" ? var.aws_connector_name : local.aws_connector_id
  prometheus_id_prefix   = var.prometheus_connector_id_prefix != "" ? var.prometheus_connector_id_prefix : "${local.prefix_id}_prometheus"
  prometheus_name_prefix = var.prometheus_connector_name_prefix != "" ? var.prometheus_connector_name_prefix : "${var.resource_prefix}-prometheus"

  environment_id   = var.environment_id != "" ? var.environment_id : local.prefix_id
  environment_name = var.environment_name != "" ? var.environment_name : local.environment_id
  # A STEM, not a full identifier. The per-project suffix is added in
  # local.projects. Four projects sharing one infra identifier also share one
  # discovery agent identity, and the agent identity is what names the
  # collector objects the delegate installs — so four agents were installing
  # and uninstalling the same objects in the same namespace, cancelling each
  # other out. Must stay lowercase alphanumeric: it becomes a Helm release
  # stem (event-watcher-<infra_id>), and Harness IDs forbid hyphens while Helm
  # forbids underscores.
  infra_id_stem         = var.infra_id != "" ? var.infra_id : "${replace(var.resource_prefix, "-", "")}k8s"
  infra_name            = var.infra_name != "" ? var.infra_name : "${var.resource_prefix}-k8s"
  discovery_name_prefix = var.discovery_agent_name_prefix != "" ? var.discovery_agent_name_prefix : "${var.resource_prefix}-discovery"
  chaos_name_prefix     = var.chaos_infra_name_prefix != "" ? var.chaos_infra_name_prefix : "${var.resource_prefix}-chaos"

  team_prefix_id   = var.project_identifier_prefix != "" ? var.project_identifier_prefix : "team"
  team_prefix_name = var.project_name_prefix != "" ? var.project_name_prefix : "team"

  org_identifier = var.create_organization ? harness_platform_organization.this[0].identifier : data.harness_platform_organization.this[0].identifier

  discovery_install_ns = (
    var.discovery_install_namespace != ""
    ? var.discovery_install_namespace
    : var.delegate_namespace
  )

  ns_index = {
    for ns in local.namespaces : ns => (
      can(regex("[0-9]+$", ns)) ? regex("[0-9]+$", ns) : replace(ns, "-", "_")
    )
  }

  projects = {
    for ns in local.namespaces : ns => {
      namespace  = ns
      index      = local.ns_index[ns]
      identifier = coalesce(try(var.project_overrides[ns].identifier, null), "${local.team_prefix_id}_${local.ns_index[ns]}")
      name       = coalesce(try(var.project_overrides[ns].name, null), "${local.team_prefix_name}-${local.ns_index[ns]}")
      # ns_index falls back to the namespace with hyphens turned into
      # underscores when it does not end in digits, and an underscore here
      # would produce an invalid Helm release stem. Strip to alphanumerics.
      infra_id = "${local.infra_id_stem}${lower(replace(local.ns_index[ns], "/[^0-9A-Za-z]/", ""))}"
    }
  }
}

# -----------------------------------------------------------------------------
# Organization
# -----------------------------------------------------------------------------

resource "harness_platform_organization" "this" {
  count = var.create_organization ? 1 : 0

  identifier  = local.org_id
  name        = local.org_name
  description = var.org_description
  tags        = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

data "harness_platform_organization" "this" {
  count = var.create_organization ? 0 : 1

  identifier = local.org_id
}

# -----------------------------------------------------------------------------
# Org ChaosHub + experiment templates
# Registry: data.harness_chaos_hub_v2 (existing custom-hub-workshop),
# chaos_experiment_template. Org-scoped: org_id set, project_id omitted.
# Does not create a ChaosHub, probe template, or action template.
# Experiment identities/names match PnC and the live workshop hub
# (e.g. txnservicedependencyfailure). import {} adopts those objects so
# apply updates them. Per-project harness_chaos_experiment.from_template
# is still skipped unless experiment_* identities are set.
# -----------------------------------------------------------------------------

locals {
  chaos_hub_name = var.chaos_hub_name != "" ? var.chaos_hub_name : var.chaos_hub_identity
  chaos_hub_ref  = "org.${var.chaos_hub_identity}"

  # Existing probe/action identities in custom-hub-workshop (do not create new ones).
  chaos_probe_txn_id  = "hpb-transation-svc-health-check"
  chaos_probe_user_id = "banking-user-api-check"
  chaos_delay_id      = "delay-action-template"

  # TARGET_NAMESPACE picker: only banking-i for project team_i.
  # Probe/fault DNS cannot use experiment.variables (provider spec has no
  # variables block), so those strings derive the same namespace from the project.
  chaos_ns_from_project = "<+replace(<+project.identifier>,\"team_\",\"banking-\")>"
  chaos_ns_input        = "<+input>.allowedValues(<+replace(<+project.identifier>,\"team_\",\"banking-\")>)"
  chaos_ns              = local.chaos_ns_input
  chaos_gateway_dns     = "gateway-service.<+replace(<+project.identifier>,\"team_\",\"banking-\")>"
  chaos_postgres_dns    = "postgresql.<+replace(<+project.identifier>,\"team_\",\"banking-\")>.svc.cluster.local"
  chaos_url = {
    gateway_health = "http://gateway-service.<+replace(<+project.identifier>,\"team_\",\"banking-\")>:8080/actuator/health"
    gateway_txn    = "http://gateway-service.<+replace(<+project.identifier>,\"team_\",\"banking-\")>:8080/api/v1/transactions/account/1?page=0&size=20&sort=createdAt,desc"
    gateway_user   = "http://gateway-service.<+replace(<+project.identifier>,\"team_\",\"banking-\")>:8080/api/v1/accounts/user/4"
  }
  chaos_probe_values = {
    health = [
      { name = "URL", value = "http://gateway-service.<+replace(<+project.identifier>,\"team_\",\"banking-\")>:8080/actuator/health" },
      { name = "AUTH_CREDENTIALS", value = "<+input>" },
    ]
    txn = [
      { name = "URL", value = "http://gateway-service.<+replace(<+project.identifier>,\"team_\",\"banking-\")>:8080/api/v1/transactions/account/1?page=0&size=20&sort=createdAt,desc" },
      { name = "AUTH_CREDENTIALS", value = "<+input>" },
    ]
    user = [
      { name = "URL", value = "http://gateway-service.<+replace(<+project.identifier>,\"team_\",\"banking-\")>:8080/api/v1/accounts/user/4" },
      { name = "AUTH_CREDENTIALS", value = "<+input>" },
    ]
  }

  chaos_experiment_templates = {
    gateway_pod_delete = {
      identity    = "gatewayservicepodrestart"
      name        = "gateway-service-pod-restart"
      description = "Delete gateway-service pods and check gateway APIs before, during, and after the fault. Namespace is TARGET_NAMESPACE; probe URLs use in-cluster DNS gateway-service.<namespace>."
      tags        = ["hpb", "gateway", "pod-delete"]
      faults = [{
        identity = "pod-delete"
        name     = "gateway-pod-delete-fault"
        values = [
          { name = "TARGET_WORKLOAD_KIND", value = "deployment" },
          { name = "TARGET_WORKLOAD_NAMES", value = "gateway-service" },
          { name = "TARGET_WORKLOAD_NAMESPACE", value = local.chaos_ns },
          { name = "TOTAL_CHAOS_DURATION", value = "120" },
          { name = "POD_AFFECTED_PERCENTAGE", value = "100" },
          { name = "CHAOS_INTERVAL", value = "20" },
        ]
      }]
      probes = [
        {
          name   = "probe-txn-pre", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-health", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.health
        },
        {
          name   = "probe-user", identity = local.chaos_probe_user_id, duration = "30s"
          values = local.chaos_probe_values.user
        },
        {
          name   = "probe-txn-post", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
      ]
      actions = []
      vertices = [
        { name = "pre", start = { probes = ["probe-txn-pre"] }, end = {} },
        { name = "fault", start = { probes = ["probe-health", "probe-user"], faults = ["gateway-pod-delete-fault"] }, end = { probes = ["probe-txn-pre"] } },
        { name = "post", start = { probes = ["probe-txn-post"] }, end = { probes = ["probe-health", "probe-user"], faults = ["gateway-pod-delete-fault"] } },
        { name = "v-end", start = {}, end = { probes = ["probe-txn-post"] } },
      ]
    }

    gateway_cpu_hog = {
      identity    = "gatewaysvccpuhog"
      name        = "gateway-svc-cpu-hog"
      description = "CPU hog on gateway-service with a delay action around the fault. HTTP probe uses in-cluster DNS gateway-service.<TARGET_NAMESPACE>."
      tags        = ["hpb", "gateway", "cpu-hog"]
      faults = [{
        identity = "pod-cpu-hog"
        name     = "gateway-cpu-hog-fault"
        values = [
          { name = "TARGET_WORKLOAD_KIND", value = "deployment" },
          { name = "TARGET_WORKLOAD_NAMES", value = "gateway-service" },
          { name = "TARGET_WORKLOAD_NAMESPACE", value = local.chaos_ns },
          { name = "TOTAL_CHAOS_DURATION", value = "120" },
          { name = "POD_AFFECTED_PERCENTAGE", value = "100" },
          { name = "CPU_CORES", value = "2" },
          { name = "CPU_LOAD", value = "100" },
        ]
      }]
      probes = [
        {
          name   = "probe-during", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.health
        },
      ]
      actions = [{
        identity = local.chaos_delay_id
        name     = "delay-30s"
        values   = [{ name = "DURATION", value = "30s" }]
      }]
      vertices = [
        { name = "pre", start = { actions = ["delay-30s"] }, end = {} },
        { name = "fault", start = { probes = ["probe-during"], faults = ["gateway-cpu-hog-fault"] }, end = { actions = ["delay-30s"] } },
        { name = "v-end", start = {}, end = { probes = ["probe-during"], faults = ["gateway-cpu-hog-fault"] } },
      ]
    }

    service_pod_delete = {
      identity    = "servicerestart"
      name        = "service-restart"
      description = "Generic pod-delete against a workload name and namespace supplied at import/run time."
      tags        = ["hpb", "pod-delete"]
      faults = [{
        identity = "pod-delete"
        name     = "service-pod-delete-fault"
        values = [
          { name = "TARGET_WORKLOAD_KIND", value = "deployment" },
          { name = "TARGET_WORKLOAD_NAMES", value = "<+input>" },
          { name = "TARGET_WORKLOAD_NAMESPACE", value = local.chaos_ns },
          { name = "TOTAL_CHAOS_DURATION", value = "120" },
          { name = "POD_AFFECTED_PERCENTAGE", value = "100" },
          { name = "CHAOS_INTERVAL", value = "20" },
        ]
      }]
      probes = [
        {
          name   = "probe-pre", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.health
        },
        {
          name   = "probe-during", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-post", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
      ]
      actions = []
      vertices = [
        { name = "pre", start = { probes = ["probe-pre"] }, end = {} },
        { name = "fault", start = { probes = ["probe-during"], faults = ["service-pod-delete-fault"] }, end = { probes = ["probe-pre"] } },
        { name = "post", start = { probes = ["probe-post"] }, end = { probes = ["probe-during"], faults = ["service-pod-delete-fault"] } },
        { name = "v-end", start = {}, end = { probes = ["probe-post"] } },
      ]
    }

    transaction_sql_exception = {
      identity    = "transactionsqlinjectexception"
      name        = "transaction-sql-inject-exception"
      description = "JVM SQL exception on transaction-service SELECT against the transactions table (Hibernate)."
      tags        = ["hpb", "transaction-service", "jvm"]
      faults = [{
        identity = "pod-jvm-sql-exception"
        name     = "txn-sql-exception-fault"
        values = [
          { name = "TARGET_WORKLOAD_KIND", value = "deployment" },
          { name = "TARGET_WORKLOAD_NAMES", value = "transaction-service" },
          { name = "TARGET_WORKLOAD_NAMESPACE", value = local.chaos_ns },
          { name = "TOTAL_CHAOS_DURATION", value = "120" },
          { name = "TABLE", value = "transactions" },
          { name = "SQL_OPERATION", value = "select" },
          { name = "SQL_DATA_ACCESS_FRAMEWORK", value = "HIBERNATE" },
        ]
      }]
      probes = [
        {
          name   = "probe-pre", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-during", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-post", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
      ]
      actions = []
      vertices = [
        { name = "pre", start = { probes = ["probe-pre"] }, end = {} },
        { name = "fault", start = { probes = ["probe-during"], faults = ["txn-sql-exception-fault"] }, end = { probes = ["probe-pre"] } },
        { name = "post", start = { probes = ["probe-post"] }, end = { probes = ["probe-during"], faults = ["txn-sql-exception-fault"] } },
        { name = "v-end", start = {}, end = { probes = ["probe-post"] } },
      ]
    }

    transaction_network_loss = {
      identity    = "txnservicedependencyfailure"
      name        = "txn-service-dependency-failure"
      description = "Block transaction-service traffic to gateway-service (dependency failure)."
      tags        = ["hpb", "transaction-service", "network"]
      faults = [{
        identity = "pod-network-loss"
        name     = "txn-network-loss-fault"
        values = [
          { name = "TARGET_WORKLOAD_KIND", value = "deployment" },
          { name = "TARGET_WORKLOAD_NAMES", value = "transaction-service" },
          { name = "TARGET_WORKLOAD_NAMESPACE", value = local.chaos_ns },
          { name = "TOTAL_CHAOS_DURATION", value = "120" },
          { name = "POD_AFFECTED_PERCENTAGE", value = "100" },
          { name = "DESTINATION_HOSTS", value = local.chaos_gateway_dns },
        ]
      }]
      probes = [
        {
          name   = "probe-pre", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-during", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-post", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
      ]
      actions = []
      vertices = [
        { name = "pre", start = { probes = ["probe-pre"] }, end = {} },
        { name = "fault", start = { probes = ["probe-during"], faults = ["txn-network-loss-fault"] }, end = { probes = ["probe-pre"] } },
        { name = "post", start = { probes = ["probe-post"] }, end = { probes = ["probe-during"], faults = ["txn-network-loss-fault"] } },
        { name = "v-end", start = {}, end = { probes = ["probe-post"] } },
      ]
    }

    account_db_network_loss = {
      identity    = "accountsvcdbfailure"
      name        = "account-svc-db-failure"
      description = "Network loss from account-service to PostgreSQL at postgresql.<TARGET_NAMESPACE>.svc.cluster.local."
      tags        = ["hpb", "account-service", "network"]
      faults = [{
        identity = "pod-network-loss"
        name     = "account-db-network-loss-fault"
        values = [
          { name = "TARGET_WORKLOAD_KIND", value = "deployment" },
          { name = "TARGET_WORKLOAD_NAMES", value = "account-service" },
          { name = "TARGET_WORKLOAD_NAMESPACE", value = local.chaos_ns },
          { name = "TOTAL_CHAOS_DURATION", value = "120" },
          { name = "DESTINATION_HOSTS", value = local.chaos_postgres_dns },
        ]
      }]
      probes = [
        {
          name   = "probe-pre", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-during", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.user
        },
        {
          name   = "probe-post", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
      ]
      actions = []
      vertices = [
        { name = "pre", start = { probes = ["probe-pre"] }, end = {} },
        { name = "fault", start = { probes = ["probe-during"], faults = ["account-db-network-loss-fault"] }, end = { probes = ["probe-pre"] } },
        { name = "post", start = { probes = ["probe-post"] }, end = { probes = ["probe-during"], faults = ["account-db-network-loss-fault"] } },
        { name = "v-end", start = {}, end = { probes = ["probe-post"] } },
      ]
    }

    account_jvm_method_exception = {
      identity    = "accountsvcjavamethodexception"
      name        = "account-svc-java-method-exception"
      description = "NullPointerException on AccountService.getAccountsByUserId in account-service."
      tags        = ["hpb", "account-service", "jvm"]
      faults = [{
        identity = "pod-jvm-method-exception"
        name     = "account-jvm-method-fault"
        values = [
          { name = "TARGET_WORKLOAD_KIND", value = "deployment" },
          { name = "TARGET_WORKLOAD_NAMES", value = "account-service" },
          { name = "TARGET_WORKLOAD_NAMESPACE", value = local.chaos_ns },
          { name = "TOTAL_CHAOS_DURATION", value = "120" },
          { name = "POD_AFFECTED_PERCENTAGE", value = "100" },
          { name = "CLASS", value = "com.example.account.service.AccountService" },
          { name = "METHOD", value = "getAccountsByUserId" },
          { name = "EXCEPTION", value = "NullPointerException(\"Hello, NullPointerException!\")" },
        ]
      }]
      probes = [
        {
          name   = "probe-pre", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-during", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.user
        },
        {
          name   = "probe-post", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
      ]
      actions = []
      vertices = [
        { name = "pre", start = { probes = ["probe-pre"] }, end = {} },
        { name = "fault", start = { probes = ["probe-during"], faults = ["account-jvm-method-fault"] }, end = { probes = ["probe-pre"] } },
        { name = "post", start = { probes = ["probe-post"] }, end = { probes = ["probe-during"], faults = ["account-jvm-method-fault"] } },
        { name = "v-end", start = {}, end = { probes = ["probe-post"] } },
      ]
    }

    account_api_status_code = {
      identity    = "accountsvcegressapistatuscodechange"
      name        = "account-svc-egress-api-status-code-change"
      description = "Force HTTP 500 on account-service ingress /user for 100% of traffic."
      tags        = ["hpb", "account-service", "http"]
      faults = [{
        identity = "pod-api-status-code"
        name     = "account-api-status-fault"
        values = [
          { name = "TARGET_WORKLOAD_KIND", value = "deployment" },
          { name = "TARGET_WORKLOAD_NAMES", value = "account-service" },
          { name = "TARGET_WORKLOAD_NAMESPACE", value = local.chaos_ns },
          { name = "TOTAL_CHAOS_DURATION", value = "120" },
          { name = "STATUS_CODE", value = "500" },
          { name = "TARGET_SERVICE_PORT", value = "10080" },
          { name = "TRANSACTION_PERCENTAGE", value = "100" },
          { name = "SERVICE_DIRECTION", value = "ingress" },
          { name = "POD_AFFECTED_PERCENTAGE", value = "100" },
        ]
      }]
      probes = [
        {
          name   = "probe-pre", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.user
        },
        {
          name   = "probe-during", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.user
        },
        {
          name   = "probe-post", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
      ]
      actions = []
      vertices = [
        { name = "pre", start = { probes = ["probe-pre"] }, end = {} },
        { name = "fault", start = { probes = ["probe-during"], faults = ["account-api-status-fault"] }, end = { probes = ["probe-pre"] } },
        { name = "post", start = { probes = ["probe-post"] }, end = { probes = ["probe-during"], faults = ["account-api-status-fault"] } },
        { name = "v-end", start = {}, end = { probes = ["probe-post"] } },
      ]
    }

    notification_mongo_exception = {
      identity    = "emailservicemongoexception"
      name        = "emailservice-mongo-exception"
      description = "JVM Mongo exception on notification-service collection notification_logs."
      tags        = ["hpb", "notification-service", "jvm"]
      faults = [{
        identity = "pod-jvm-mongo-exception"
        name     = "notification-mongo-fault"
        values = [
          { name = "TARGET_WORKLOAD_KIND", value = "deployment" },
          { name = "TARGET_WORKLOAD_NAMES", value = "notification-service" },
          { name = "TARGET_WORKLOAD_NAMESPACE", value = local.chaos_ns },
          { name = "TOTAL_CHAOS_DURATION", value = "120" },
          { name = "DATABASE", value = "notification" },
          { name = "COLLECTION", value = "notification_logs" },
          { name = "TRANSACTION_PERCENTAGE", value = "100" },
          { name = "POD_AFFECTED_PERCENTAGE", value = "100" },
        ]
      }]
      probes = [
        {
          name   = "probe-pre", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-during", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-post", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
      ]
      actions = []
      vertices = [
        { name = "pre", start = { probes = ["probe-pre"] }, end = {} },
        { name = "fault", start = { probes = ["probe-during"], faults = ["notification-mongo-fault"] }, end = { probes = ["probe-pre"] } },
        { name = "post", start = { probes = ["probe-post"] }, end = { probes = ["probe-during"], faults = ["notification-mongo-fault"] } },
        { name = "v-end", start = {}, end = { probes = ["probe-post"] } },
      ]
    }

    validator_kafka_exception = {
      identity    = "kafkaexceptioninpaymentvalidatorservice"
      name        = "kafka-exception-in-payment-validator-service"
      description = "JVM Kafka exception on validator-service topic transfer."
      tags        = ["hpb", "validator-service", "jvm"]
      faults = [{
        identity = "pod-jvm-kafka-exception"
        name     = "validator-kafka-fault"
        values = [
          { name = "TARGET_WORKLOAD_KIND", value = "deployment" },
          { name = "TARGET_WORKLOAD_NAMES", value = "validator-service" },
          { name = "TARGET_WORKLOAD_NAMESPACE", value = local.chaos_ns },
          { name = "TOTAL_CHAOS_DURATION", value = "120" },
          { name = "KAFKA_TOPIC", value = "transfer" },
          { name = "TRANSACTION_PERCENTAGE", value = "100" },
          { name = "POD_AFFECTED_PERCENTAGE", value = "100" },
        ]
      }]
      probes = [
        {
          name   = "probe-pre", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-during", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
        {
          name   = "probe-post", identity = local.chaos_probe_txn_id, duration = "30s"
          values = local.chaos_probe_values.txn
        },
      ]
      actions = []
      vertices = [
        { name = "pre", start = { probes = ["probe-pre"] }, end = {} },
        { name = "fault", start = { probes = ["probe-during"], faults = ["validator-kafka-fault"] }, end = { probes = ["probe-pre"] } },
        { name = "post", start = { probes = ["probe-post"] }, end = { probes = ["probe-during"], faults = ["validator-kafka-fault"] } },
        { name = "v-end", start = {}, end = { probes = ["probe-post"] } },
      ]
    }
  }
}

data "harness_chaos_hub_v2" "org" {
  count = var.create_org_chaos_templates ? 1 : 0

  org_id   = local.org_identifier
  identity = var.chaos_hub_identity
}

import {
  for_each = var.create_org_chaos_templates && var.adopt_existing_org_chaos_templates ? local.chaos_experiment_templates : {}
  to       = harness_chaos_experiment_template.this[each.key]
  id       = "${local.org_identifier}/${var.chaos_hub_identity}/${each.value.identity}"
}

resource "harness_chaos_experiment_template" "this" {
  for_each = var.create_org_chaos_templates ? local.chaos_experiment_templates : {}

  org_id       = local.org_identifier
  hub_identity = data.harness_chaos_hub_v2.org[0].identity
  identity     = each.value.identity
  name         = each.value.name
  description  = each.value.description
  tags         = concat(local.tags, each.value.tags)

  spec {
    infra_type     = "KubernetesV2"
    cleanup_policy = "delete"

    dynamic "faults" {
      for_each = each.value.faults
      content {
        identity      = faults.value.identity
        name          = faults.value.name
        revision      = "v1"
        is_enterprise = true
        auth_enabled  = false

        dynamic "values" {
          for_each = faults.value.values
          content {
            name  = values.value.name
            value = values.value.value
          }
        }
      }
    }

    dynamic "probes" {
      for_each = each.value.probes
      content {
        identity      = probes.value.identity
        name          = probes.value.name
        is_enterprise = false
        weightage     = 10
        duration      = probes.value.duration

        dynamic "values" {
          for_each = try(probes.value.values, [])
          content {
            name  = values.value.name
            value = values.value.value
          }
        }
      }
    }

    dynamic "actions" {
      for_each = each.value.actions
      content {
        identity               = actions.value.identity
        name                   = actions.value.name
        is_enterprise          = false
        continue_on_completion = false

        dynamic "values" {
          for_each = actions.value.values
          content {
            name  = values.value.name
            value = values.value.value
          }
        }
      }
    }

    dynamic "vertices" {
      for_each = each.value.vertices
      content {
        name = vertices.value.name

        start {
          dynamic "faults" {
            for_each = try(vertices.value.start.faults, [])
            content {
              name = faults.value
            }
          }

          dynamic "probes" {
            for_each = try(vertices.value.start.probes, [])
            content {
              name = probes.value
            }
          }

          dynamic "actions" {
            for_each = try(vertices.value.start.actions, [])
            content {
              name = actions.value
            }
          }
        }

        end {
          dynamic "faults" {
            for_each = try(vertices.value.end.faults, [])
            content {
              name = faults.value
            }
          }

          dynamic "probes" {
            for_each = try(vertices.value.end.probes, [])
            content {
              name = probes.value
            }
          }

          dynamic "actions" {
            for_each = try(vertices.value.end.actions, [])
            content {
              name = actions.value
            }
          }
        }
      }
    }
  }

  depends_on = [data.harness_chaos_hub_v2.org]
}

# -----------------------------------------------------------------------------
# Projects (one per Kubernetes namespace)
# -----------------------------------------------------------------------------

resource "harness_platform_project" "this" {
  for_each = local.projects

  identifier  = each.value.identifier
  name        = each.value.name
  org_id      = local.org_identifier
  description = "HPB chaos workshop project targeting Kubernetes namespace ${each.value.namespace}"
  color       = var.project_color
  tags        = concat(local.tags, ["namespace:${each.value.namespace}"])
}

# -----------------------------------------------------------------------------
# Delegate (account-scoped token + Helm on the EKS cluster)
# -----------------------------------------------------------------------------

# ACCOUNT-scoped deliberately: no org_id. The delegate that actually registers
# was installed from account-level settings
# (/account/<acct>/module/chaos/settings/delegates/list — note there is no
# /orgs/<org>/ segment), so its token is account-scoped. An org_id here made
# this token org-scoped while the Helm chart still registered at account level
# with accountId only, and every call came back 401 ACCOUNT_DOES_NOT_EXIST.
# Removing org_id replaces the token, which is intended: the new value flows
# into helm_release.delegate and the delegate re-registers.
resource "harness_platform_delegatetoken" "this" {
  name       = local.delegate_token_name
  account_id = var.account_id
}

resource "kubernetes_namespace_v1" "delegate" {
  metadata {
    name = var.delegate_namespace
    labels = {
      "app.kubernetes.io/name"       = "harness-delegate"
      "app.kubernetes.io/part-of"    = "hpb-workshop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Set manage_delegate = false when the delegate was installed by hand from the
# Harness UI. Terraform would otherwise re-assert its own managerEndpoint,
# accountId and token on every apply and push a working delegate straight back
# into ACCOUNT_DOES_NOT_EXIST. delegate_ready still verifies it is Ready either
# way, so the rest of the graph keeps its ordering guarantee.
resource "helm_release" "delegate" {
  count = var.manage_delegate ? 1 : 0

  name       = local.delegate_name
  namespace  = kubernetes_namespace_v1.delegate.metadata[0].name
  repository = "https://app.harness.io/storage/harness-download/delegate-helm-chart/"
  chart      = "harness-delegate-ng"

  create_namespace = false
  # Ready is polled by null_resource.delegate_ready so Helm is not killed by wait timeout.
  wait            = false
  wait_for_jobs   = false
  atomic          = false
  timeout         = var.delegate_helm_timeout
  cleanup_on_fail = false
  max_history     = 5
  # Cluster already has this release from a prior apply that never wrote state.
  upgrade_install = true
  take_ownership  = true

  # Mirrors the UI install command that registers successfully. tags and
  # k8sPermissionsType are additions: tags backs delegate_selectors on the
  # connectors, CLUSTER_ADMIN is needed for chaos and discovery.
  set = concat(
    [
      {
        name  = "delegateName"
        value = local.delegate_name
      },
      {
        name  = "accountId"
        value = var.account_id
      },
      {
        name  = "managerEndpoint"
        value = var.manager_endpoint
      },
      {
        name  = "replicas"
        value = tostring(var.delegate_replicas)
      },
      {
        name  = "nextGen"
        value = "true"
      },
      {
        name  = "k8sPermissionsType"
        value = "CLUSTER_ADMIN"
      },
      {
        name  = "upgrader.enabled"
        value = "false"
      },
      {
        name  = "tags"
        value = local.delegate_name
      },
    ],
    var.delegate_docker_image != "" ? [
      {
        name  = "delegateDockerImage"
        value = var.delegate_docker_image
      },
    ] : [],
  )

  set_sensitive = [
    {
      name  = "delegateToken"
      value = local.delegate_token
    },
  ]

  depends_on = [
    harness_platform_delegatetoken.this,
    kubernetes_namespace_v1.delegate,
  ]
}

resource "null_resource" "delegate_ready" {
  triggers = {
    release = var.manage_delegate ? helm_release.delegate[0].id : "externally-installed"
    retries = tostring(var.apply_retries)
    delay   = tostring(var.apply_retry_interval)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NS=${jsonencode(var.delegate_namespace)}
      NAME=${jsonencode(local.delegate_name)}
      CLUSTER=${jsonencode(local.cluster_name)}
      REGION=${jsonencode(var.aws_region)}
      RETRIES=${var.apply_retries}
      DELAY=${var.apply_retry_interval}
      KUBECONFIG_FILE="/tmp/hpb-delegate.kubeconfig"
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$KUBECONFIG_FILE"
      export KUBECONFIG="$KUBECONFIG_FILE"
      echo "Waiting for delegate $NAME in $NS on cluster $CLUSTER (up to $RETRIES attempts, $${DELAY}s apart)"
      i=1
      while [ "$i" -le "$RETRIES" ]; do
        echo "delegate ready attempt $i/$RETRIES"
        if kubectl get ns "$NS" >/dev/null 2>&1; then
          # Only condition=Ready is trusted. A previous fallback grepped for
          # 'Running|1/1', which matches the literal "0/1   Running" of a
          # crash-looping delegate — so this gate went green over a delegate
          # with 200+ restarts, and every downstream delegate task (including
          # the discovery collector install) silently never ran.
          if kubectl wait --for=condition=Ready pod -n "$NS" -l app.kubernetes.io/instance="$NAME" --timeout=45s 2>/dev/null; then
            echo "Delegate pods Ready"
            exit 0
          fi
        fi
        if [ "$i" -eq "$RETRIES" ]; then
          echo "Delegate not Ready after $RETRIES attempts on $CLUSTER; re-run terraform apply (do not destroy)"
          kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$NAME" -o wide || true
          echo "--- restart count / last termination ---"
          kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$NAME" \
            -o 'jsonpath={range .items[*]}{.metadata.name}{"  restarts="}{.status.containerStatuses[0].restartCount}{"  lastState="}{.status.containerStatuses[0].lastState}{"\n"}{end}' || true
          echo "--- probe failures ---"
          kubectl describe pod -n "$NS" -l app.kubernetes.io/instance="$NAME" 2>/dev/null | grep -iE 'probe|unhealthy|oomkill|killing|backoff' || true
          echo "--- delegate logs (previous container) ---"
          kubectl logs -n "$NS" -l app.kubernetes.io/instance="$NAME" --tail=80 --previous 2>/dev/null || true
          echo "--- delegate logs (current container) ---"
          kubectl logs -n "$NS" -l app.kubernetes.io/instance="$NAME" --tail=80 2>/dev/null || true
          exit 1
        fi
        sleep "$DELAY"
        i=$((i + 1))
      done
    EOT
  }

  depends_on = [helm_release.delegate]
}

resource "time_sleep" "delegate_register" {
  create_duration = var.delegate_register_wait
  depends_on      = [null_resource.delegate_ready]
}

# -----------------------------------------------------------------------------
# Connectors. K8s + Prometheus are per project. Optional AWS stays org-level.
# InheritFromDelegate — same spec as a Connector recipe; NG has no Connector template type.
# -----------------------------------------------------------------------------

resource "harness_platform_connector_kubernetes" "eks" {
  for_each = local.projects

  identifier   = local.k8s_connector_id
  name         = local.k8s_connector_name
  org_id       = local.org_identifier
  project_id   = harness_platform_project.this[each.key].identifier
  description  = "Project Kubernetes connector for namespace ${each.value.namespace} (InheritFromDelegate)."
  tags         = concat(local.tags, ["namespace:${each.value.namespace}"])
  force_delete = true

  inherit_from_delegate {
    delegate_selectors = [local.delegate_name]
  }

  depends_on = [
    time_sleep.delegate_register,
    harness_platform_project.this,
  ]
}

resource "harness_platform_connector_aws" "eks" {
  count = var.create_aws_connector ? 1 : 0

  identifier          = local.aws_connector_id
  name                = local.aws_connector_name
  org_id              = local.org_identifier
  description         = "Org AWS connector (InheritFromDelegate)."
  tags                = local.tags
  execute_on_delegate = true
  force_delete        = true

  inherit_from_delegate {
    delegate_selectors = [local.delegate_name]
    region             = var.aws_region
  }

  depends_on = [time_sleep.delegate_register]
}

resource "harness_platform_connector_prometheus" "namespace" {
  for_each = var.create_prometheus_connectors ? local.projects : {}

  identifier  = "${local.prometheus_id_prefix}_${each.value.identifier}"
  name        = "${local.prometheus_name_prefix}-${each.value.name}"
  org_id      = local.org_identifier
  project_id  = harness_platform_project.this[each.key].identifier
  description = "Prometheus in namespace ${each.value.namespace}."
  tags        = concat(local.tags, ["namespace:${each.value.namespace}"])
  # Trailing slash is not cosmetic: the API stores the URL normalised with one,
  # so writing it without produces an update-in-place on every single plan.
  url                = "http://prometheus.${each.value.namespace}.svc.cluster.local:${var.prometheus_port}/"
  delegate_selectors = [local.delegate_name]

  depends_on = [
    time_sleep.delegate_register,
    harness_platform_project.this,
  ]
}

# -----------------------------------------------------------------------------
# Per project: environment, Kubernetes infra, discovery, chaos v2
# -----------------------------------------------------------------------------

resource "harness_platform_environment" "this" {
  for_each = local.projects

  identifier   = local.environment_id
  name         = local.environment_name
  org_id       = local.org_identifier
  project_id   = harness_platform_project.this[each.key].identifier
  type         = var.environment_type
  description  = "HPB workshop environment for namespace ${each.value.namespace}"
  tags         = concat(local.tags, ["namespace:${each.value.namespace}"])
  force_delete = true
}

# The API stores the tags declared in the YAML body and ignores anything extra
# in the tags attribute, so the two must be generated from one list. Hardcoding
# only workshop + namespace in the YAML while the attribute also carried
# project + managedby meant those two never persisted and every plan re-issued
# the same in-place tag update forever.
locals {
  infra_tags = {
    for k, p in local.projects : k => concat(local.tags, ["namespace:${p.namespace}"])
  }

  # Split on the first colon only, so a value containing one (a URL, say)
  # survives instead of being silently truncated.
  infra_tags_yaml = {
    for k, tags in local.infra_tags : k => join("\n", [
      for t in tags : format("    %s: %q",
        split(":", t)[0],
        join(":", slice(split(":", t), 1, length(split(":", t))))
      )
    ])
  }
}

resource "harness_platform_infrastructure" "this" {
  for_each = local.projects

  identifier      = each.value.infra_id
  name            = local.infra_name
  org_id          = local.org_identifier
  project_id      = harness_platform_project.this[each.key].identifier
  env_id          = harness_platform_environment.this[each.key].identifier
  type            = "KubernetesDirect"
  deployment_type = "Kubernetes"
  force_delete    = true
  tags            = local.infra_tags[each.key]

  lifecycle {
    create_before_destroy = true
  }

  yaml = <<-EOT
infrastructureDefinition:
  name: ${local.infra_name}
  identifier: ${each.value.infra_id}
  orgIdentifier: ${local.org_identifier}
  projectIdentifier: ${each.value.identifier}
  environmentRef: ${local.environment_id}
  description: HPB workshop Kubernetes infrastructure for ${each.value.namespace}
  tags:
${local.infra_tags_yaml[each.key]}
  deploymentType: Kubernetes
  type: KubernetesDirect
  spec:
    connectorRef: ${local.k8s_connector_id}
    namespace: ${each.value.namespace}
    releaseName: release-<+INFRA_KEY>
  allowSimultaneousDeployments: true
  EOT

  depends_on = [
    harness_platform_environment.this,
    harness_platform_connector_kubernetes.eks,
  ]
}

# Stale state: agents were deleted in Harness (or imported under the wrong id
# hpb_k8s) so refresh returns 404. Drop them from state without a destroy API
# call, then create a new resource address bound to hpbk8s.
# Pipeline: enable Skip Refresh Command on TerraformApply_2 (not TF_CLI_ARGS_apply).
removed {
  from = harness_service_discovery_agent.this
  lifecycle { destroy = false }
}

# PnC DA-banking-1: install ns harness-delegate-ng, SA chaos-delegate,
# cron 0/15, Inclusion banking-1, network trace OFF, static configmap name OFF.
# Docs (single namespace + Inclusion): "Disable the Detect network trace
# connectivity." Leaving it on makes the form demand a node selector and the
# collector never runs (Last Discovery: N/A).
resource "kubernetes_service_account_v1" "discovery" {
  count = var.create_discovery_service_account ? 1 : 0

  metadata {
    name      = var.discovery_service_account
    namespace = kubernetes_namespace_v1.delegate.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "harness-service-discovery"
      "app.kubernetes.io/part-of"    = "hpb-workshop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Cluster-wide read so the collector can list Namespace objects, which is what
# populates the Namespace dropdown when scoping with Inclusion.
resource "kubernetes_cluster_role_binding_v1" "discovery" {
  count = var.create_discovery_service_account ? 1 : 0

  metadata {
    name = "${var.discovery_service_account}-cluster-admin"
    labels = {
      "app.kubernetes.io/part-of"    = "hpb-workshop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.discovery[0].metadata[0].name
    namespace = kubernetes_namespace_v1.delegate.metadata[0].name
  }
}

# Bump discovery_scope_version to force a reinstall after changing install
# namespace, service account or cron.
#
# Do NOT reintroduce a kubectl-based "is the collector running" probe here. The
# collector is a short-lived Job (reported by the API as sd-cluster-<suffix>,
# status Succeeded) that is garbage-collected once it finishes, so its absence
# from the cluster says nothing at all — an earlier version of this file polled
# for a CronJob that never exists in any state and failed a perfectly healthy
# apply. Read installation_details and service_count in the
# discovery_installation output instead: that is the API's own answer.
resource "terraform_data" "discovery_cluster_scope" {
  input = var.discovery_scope_version
}

# org_identifier, project_identifier, environment_identifier and
# infra_identifier are immutable server-side; the API answers an update with
# "cannot update immutable fields". The provider does not mark them ForceNew,
# so Terraform cheerfully plans an in-place update that can only fail. Bind the
# agent's replacement to them so a change recreates the agent instead.
resource "terraform_data" "discovery_agent_binding" {
  for_each = local.projects

  input = join("|", [
    local.org_identifier,
    each.value.identifier,
    local.environment_id,
    each.value.infra_id,
  ])
}

# Destroying harness_chaos_infrastructure_v2 also deleted the agent records
# behind it — they share the infra_id keyspace in the chaos service — and the
# provider answers a refresh of a deleted agent with a bare "Not Found" instead
# of dropping it from state, which makes even a plan impossible. The stale
# instances are forgotten by the removed block below; this new address builds
# the agents fresh.
resource "harness_service_discovery_agent" "agent" {
  for_each = local.projects

  name                   = "${local.discovery_name_prefix}-${each.value.name}"
  org_identifier         = local.org_identifier
  project_identifier     = harness_platform_project.this[each.key].identifier
  environment_identifier = harness_platform_environment.this[each.key].identifier
  infra_identifier       = harness_platform_infrastructure.this[each.key].identifier

  # installation_type is deliberately not set. The provider never sends it on
  # create/update (resource_agent.go only does d.Set from the API response), so
  # setting it does nothing except invite permanent drift when the API reports a
  # different value than the one in config. Ours said "CONNECTOR"; the provider
  # vocabulary is Connector / Helm / Manifest / Yaml, so it never matched.

  config {
    kubernetes {
      namespace                  = local.discovery_install_ns
      namespaced                 = false
      disable_namespace_creation = true
      service_account            = var.discovery_service_account
    }
    data {
      # Inclusion only. This list is the UI Namespace dropdown: team-1 → banking-1.
      observed_namespaces = [each.value.namespace]

      # Network trace needs a node agent + node selector + duration. PnC leaves
      # it off, so these stay null unless discovery_enable_network_trace is set.
      enable_node_agent        = var.discovery_enable_network_trace
      node_agent_selector      = var.discovery_enable_network_trace ? var.discovery_node_agent_selector : null
      collection_window_in_min = var.discovery_enable_network_trace ? var.discovery_collection_window_in_min : null

      cron {
        expression = var.discovery_cron_expression
      }
    }
  }

  lifecycle {
    replace_triggered_by = [
      terraform_data.discovery_cluster_scope,
      terraform_data.discovery_agent_binding[each.key],
    ]

    # The API reports CONNECTOR while the provider never sends the field, so
    # leaving it unset still shows "CONNECTOR" -> null and re-PATCHes all four
    # agents on every apply.
    ignore_changes = [installation_type]
  }

  depends_on = [
    harness_platform_infrastructure.this,
    harness_platform_connector_kubernetes.eks,
    kubernetes_cluster_role_binding_v1.discovery,
    time_sleep.delegate_register,
  ]
}

# installation_details is computed by the provider from the API, so a green
# apply already knows why the collector never ran — it just never printed it.
# delegate_task_status is the answer: if there is no install task, or it failed,
# Discovery History stays completely empty and Last Discovery stays N/A no
# matter how correct the agent config is. Read these in the stage-2 apply log.
output "discovery_installation" {
  description = "Per-project discovery install status. delegate_task_status is the field that explains an empty Discovery History."
  value = {
    for k, a in harness_service_discovery_agent.agent : k => {
      name          = a.name
      identity      = a.identity
      service_count = a.service_count
      removed       = a.removed
      install = [
        for d in a.installation_details : {
          delegate_id          = d.delegate_id
          delegate_task_id     = d.delegate_task_id
          delegate_task_status = d.delegate_task_status
          is_cron_triggered    = d.is_cron_triggered
          stopped              = d.stopped
          removed              = d.removed
          log_stream_id        = d.log_stream_id
          agent_details        = d.agent_details
        }
      ]
    }
  }
}

resource "harness_chaos_infrastructure_v2" "this" {
  for_each = local.projects

  org_id         = local.org_identifier
  project_id     = harness_platform_project.this[each.key].identifier
  environment_id = harness_platform_environment.this[each.key].identifier
  infra_id       = harness_platform_infrastructure.this[each.key].identifier
  name           = "${local.chaos_name_prefix}-${each.value.name}"
  description    = "DDCR chaos infrastructure for namespace ${each.value.namespace}"
  tags           = concat(local.tags, ["namespace:${each.value.namespace}"])

  namespace          = each.value.namespace
  infra_type         = var.chaos_infra_type
  infra_scope        = var.chaos_infra_scope
  ai_enabled         = var.ai_enabled
  discovery_agent_id = coalesce(harness_service_discovery_agent.agent[each.key].identity, harness_service_discovery_agent.agent[each.key].id)
  service_account    = var.chaos_service_account

  resources {
    requests {
      cpu    = "250m"
      memory = "256Mi"
    }
    limits {
      cpu    = "500m"
      memory = "512Mi"
    }
  }

  # infra_scope is immutable per the provider docs, and the server does not
  # persist NAMESPACE on create — it stores CLUSTER and the namespace field
  # alone decides where the components land (infra_namespace reads back as
  # banking-N). A config asking for NAMESPACE therefore never converges: every
  # plan sees CLUSTER -> NAMESPACE, forces replacement, and the recreate races
  # its own delete for the account_org_project_env_identity unique index, which
  # is what returned "E11000 duplicate key" for three of four projects.
  #
  # The empty maps are the same class of noise: the API returns {} where config
  # has nothing, so each one is an in-place update on every run for no effect.
  lifecycle {
    ignore_changes = [
      infra_scope,
      annotation,
      label,
      node_selector,
    ]
  }

  depends_on = [harness_service_discovery_agent.agent]
}

resource "null_resource" "install_chaos" {
  for_each = var.apply_chaos_install_command ? local.projects : {}

  triggers = {
    infra_id = harness_chaos_infrastructure_v2.this[each.key].id
    command  = harness_chaos_infrastructure_v2.this[each.key].install_command
    cluster  = local.cluster_name
    region   = var.aws_region
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      # Not coalesce(): it rejects "" as well as null, so a null install_command
      # (which is what this API returns for connector-based DDCR) made the
      # whole apply fail with "no non-null, non-empty-string arguments".
      CMD=${jsonencode(try(harness_chaos_infrastructure_v2.this[each.key].install_command, "") == null ? "" : try(harness_chaos_infrastructure_v2.this[each.key].install_command, ""))}
      if [ -z "$${CMD}" ] || [ "$${CMD}" = "null" ]; then
        echo "No chaos install command for ${each.value.namespace}; DDCR uses connector ${local.k8s_connector_id}"
        exit 0
      fi
      RETRIES=${var.apply_retries}
      DELAY=${var.apply_retry_interval}
      KUBECONFIG_FILE="/tmp/hpb-eks-${each.value.identifier}.kubeconfig"
      i=1
      while [ "$i" -le "$RETRIES" ]; do
        echo "chaos install ${each.value.namespace} attempt $i/$RETRIES"
        if aws eks update-kubeconfig --region ${var.aws_region} --name ${local.cluster_name} --kubeconfig "$KUBECONFIG_FILE" \
          && export KUBECONFIG="$KUBECONFIG_FILE" \
          && bash -lc "$CMD"; then
          echo "Chaos install succeeded for ${each.value.namespace}"
          exit 0
        fi
        if [ "$i" -eq "$RETRIES" ]; then
          echo "Chaos install failed for ${each.value.namespace} after $RETRIES attempts; re-run terraform apply"
          exit 1
        fi
        sleep "$DELAY"
        i=$((i + 1))
      done
    EOT
  }

  depends_on = [harness_chaos_infrastructure_v2.this]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "org_id" {
  value = local.org_identifier
}

output "namespaces" {
  value = local.namespaces
}

output "projects" {
  value = {
    for ns, project in harness_platform_project.this : ns => {
      namespace  = local.projects[ns].namespace
      identifier = project.identifier
      name       = project.name
    }
  }
}

output "delegate_name" {
  value = local.delegate_name
}

output "k8s_connector_refs" {
  value = {
    for ns, connector in harness_platform_connector_kubernetes.eks :
    ns => connector.identifier
  }
}

resource "harness_chaos_experiment" "from_template" {
  for_each = var.experiment_template_identity != "" && var.experiment_hub_identity != "" ? local.projects : {}

  org_id     = local.org_identifier
  project_id = harness_platform_project.this[each.key].identifier

  hub_identity      = var.experiment_hub_identity
  hub_org_id        = var.experiment_hub_org_id != "" ? var.experiment_hub_org_id : null
  hub_project_id    = var.experiment_hub_project_id != "" ? var.experiment_hub_project_id : null
  template_identity = var.experiment_template_identity
  revision          = var.experiment_template_revision
  import_type       = var.experiment_import_type
  infra_ref         = "${local.environment_id}/${each.value.infra_id}"
  name              = var.experiment_name != "" ? var.experiment_name : var.experiment_template_identity
  identity          = replace(var.experiment_template_identity, "-", "_")
  description       = "Imported from template ${var.experiment_template_identity} for namespace ${each.value.namespace}"
  tags              = concat(local.tags, ["namespace:${each.value.namespace}"])

  lifecycle {
    ignore_changes = [tags]
  }

  depends_on = [
    harness_chaos_infrastructure_v2.this,
    harness_platform_infrastructure.this,
    harness_chaos_experiment_template.this,
  ]
}

output "chaos_hub" {
  value = var.create_org_chaos_templates ? {
    identity    = data.harness_chaos_hub_v2.org[0].identity
    name        = data.harness_chaos_hub_v2.org[0].name
    hub_ref     = local.chaos_hub_ref
    import_hint = "Set experiment_hub_identity=${local.chaos_hub_ref}, experiment_hub_org_id=${local.org_identifier}, and experiment_template_identity to a live identity such as txnservicedependencyfailure."
  } : null
}

output "chaos_experiment_templates" {
  value = {
    for key, tmpl in harness_chaos_experiment_template.this : key => {
      identity = tmpl.identity
      name     = tmpl.name
    }
  }
}

output "experiments" {
  value = {
    for ns, experiment in harness_chaos_experiment.from_template : ns => {
      name     = experiment.name
      identity = experiment.identity
      id       = experiment.id
    }
  }
}

output "aws_connector_ref" {
  value = var.create_aws_connector ? "org.${local.aws_connector_id}" : null
}

output "prometheus_connector_refs" {
  value = {
    for ns, connector in harness_platform_connector_prometheus.namespace :
    ns => connector.identifier
  }
}

output "discovery_agents" {
  value = {
    for ns, agent in harness_service_discovery_agent.agent : ns => {
      name     = agent.name
      id       = agent.id
      identity = agent.identity
      ui_url   = "https://app.harness.io/ng/account/${var.account_id}/module/chaos/orgs/${local.org_identifier}/projects/${harness_platform_project.this[ns].identifier}/settings/discovery/${coalesce(agent.identity, agent.id)}?environmentIdentifier=${local.environment_id}"
    }
  }
}

output "chaos_infrastructures" {
  value = {
    for ns, infra in harness_chaos_infrastructure_v2.this : ns => {
      name   = infra.name
      id     = infra.id
      status = infra.status
    }
  }
}
