# =============================================================================
# main.tf — org workshop → templates → team projects → delegate → connectors
# =============================================================================
# Single Terraform root. Only this file and variables.tf are Terraform language.
#
# Order:
#   1. Read infrastructure remote state (cluster + banking-N) unless overridden
#   2. Organization workshop
#   3. Projects team-N (one per namespace banking-N)
#   4. Org delegate token + Helm on EKS; wait for registration
#   5. Optional org AWS connector
#   6. Per project: K8s connector, Prometheus, environment, infra, discovery,
#      chaos v2, experiment import from a chaos hub template (if ids are set)
#
# Connector "templates" are not created here. Harness NG template types do not
# include Connector (only Step, Stage, Pipeline, …). Connectors are created
# with harness_platform_connector_* (InheritFromDelegate). Chaos experiment
# templates are a different product (hub); import uses harness_chaos_experiment.
#
# Failure / retry: do not terraform destroy this root on error. Re-run apply.
# Resources already in state are left alone; missing ones are created.
# Helm is non-atomic so a timed-out delegate is upgraded in place on retry.
# upgrade_install adopts a cluster release that is not in Terraform state
# (previous apply installed Helm, then failed before state was saved).
# CD infra identifier must be Helm-safe (hyphens, no underscores). Chaos
# event-watcher release name is event-watcher-<infra_id>.
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

  environment_id        = var.environment_id != "" ? var.environment_id : local.prefix_id
  environment_name      = var.environment_name != "" ? var.environment_name : local.environment_id
  infra_id   = var.infra_id != "" ? var.infra_id : "${var.resource_prefix}-k8s"
  infra_name = var.infra_name != "" ? var.infra_name : local.infra_id
  discovery_name_prefix = var.discovery_agent_name_prefix != "" ? var.discovery_agent_name_prefix : "${var.resource_prefix}-discovery"
  chaos_name_prefix     = var.chaos_infra_name_prefix != "" ? var.chaos_infra_name_prefix : "${var.resource_prefix}-chaos"

  team_prefix_id   = var.project_identifier_prefix != "" ? var.project_identifier_prefix : "team"
  team_prefix_name = var.project_name_prefix != "" ? var.project_name_prefix : "team"

  org_identifier = var.create_organization ? harness_platform_organization.this[0].identifier : data.harness_platform_organization.this[0].identifier

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
}

data "harness_platform_organization" "this" {
  count = var.create_organization ? 0 : 1

  identifier = local.org_id
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
# Delegate (org token + Helm on the EKS cluster)
# -----------------------------------------------------------------------------

resource "harness_platform_delegatetoken" "this" {
  name       = local.delegate_token_name
  account_id = var.account_id
  org_id     = local.org_identifier
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

resource "helm_release" "delegate" {
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

  set = [
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
  ]

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
    release = helm_release.delegate.id
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
          if kubectl wait --for=condition=Ready pod -n "$NS" -l app.kubernetes.io/instance="$NAME" --timeout=45s 2>/dev/null; then
            echo "Delegate pods Ready"
            exit 0
          fi
          if kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$NAME" --no-headers 2>/dev/null | grep -qiE 'Running|1/1'; then
            echo "Delegate pods Running"
            exit 0
          fi
        fi
        if [ "$i" -eq "$RETRIES" ]; then
          echo "Delegate not Ready after $RETRIES attempts on $CLUSTER; re-run terraform apply (do not destroy)"
          kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$NAME" || true
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

  identifier         = "${local.prometheus_id_prefix}_${each.value.identifier}"
  name               = "${local.prometheus_name_prefix}-${each.value.name}"
  org_id             = local.org_identifier
  project_id         = harness_platform_project.this[each.key].identifier
  description        = "Prometheus in namespace ${each.value.namespace}."
  tags               = concat(local.tags, ["namespace:${each.value.namespace}"])
  url                = "http://prometheus.${each.value.namespace}.svc.cluster.local:${var.prometheus_port}"
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

resource "harness_platform_infrastructure" "this" {
  for_each = local.projects

  identifier      = local.infra_id
  name            = local.infra_name
  org_id          = local.org_identifier
  project_id      = harness_platform_project.this[each.key].identifier
  env_id          = harness_platform_environment.this[each.key].identifier
  type            = "KubernetesDirect"
  deployment_type = "Kubernetes"
  force_delete    = true
  tags            = concat(local.tags, ["namespace:${each.value.namespace}"])

  lifecycle {
    create_before_destroy = true
  }

  yaml = <<-EOT
infrastructureDefinition:
  name: ${local.infra_name}
  identifier: ${local.infra_id}
  orgIdentifier: ${local.org_identifier}
  projectIdentifier: ${each.value.identifier}
  environmentRef: ${local.environment_id}
  description: HPB workshop Kubernetes infrastructure for ${each.value.namespace}
  tags:
    workshop: "true"
    namespace: ${each.value.namespace}
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

# Agents can be created in Harness then fail install (cron interval 0). They are
# not in Terraform state. Import those namespaces so retry updates instead of
# creating duplicates. Already-in-state imports are a no-op on Terraform >= 1.8.
import {
  for_each = toset(var.import_discovery_namespaces)
  to       = harness_service_discovery_agent.this[each.key]
  id       = "${local.org_id}/${local.projects[each.key].identifier}/${local.environment_id}/${local.infra_id}"
}

resource "harness_service_discovery_agent" "this" {
  for_each = local.projects

  name                   = "${local.discovery_name_prefix}-${each.value.name}"
  org_identifier         = local.org_identifier
  project_identifier     = harness_platform_project.this[each.key].identifier
  environment_identifier = harness_platform_environment.this[each.key].identifier
  infra_identifier       = harness_platform_infrastructure.this[each.key].identifier
  installation_type      = var.discovery_installation_type

  config {
    kubernetes {
      namespace                  = var.discovery_install_namespace != "" ? var.discovery_install_namespace : each.value.namespace
      namespaced                 = true
      disable_namespace_creation = true
    }
    data {
      observed_namespaces      = [each.value.namespace]
      blacklisted_namespaces   = ["kube-system", "kube-public", var.delegate_namespace]
      collection_window_in_min = 10
      cron {
        expression = var.discovery_cron_expression
      }
    }
  }

  depends_on = [
    harness_platform_infrastructure.this,
    harness_platform_connector_kubernetes.eks,
  ]
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
  discovery_agent_id = coalesce(harness_service_discovery_agent.this[each.key].identity, harness_service_discovery_agent.this[each.key].id)
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

  depends_on = [harness_service_discovery_agent.this]
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
      CMD=${jsonencode(harness_chaos_infrastructure_v2.this[each.key].install_command)}
      if [ -z "$${CMD//[[:space:]]/}" ]; then
        echo "No chaos install command for ${each.value.namespace}; DDCR will use project connector ${local.k8s_connector_id}"
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
  infra_ref         = "${local.environment_id}/${local.infra_id}"
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
  ]
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
    for ns, agent in harness_service_discovery_agent.this : ns => {
      name     = agent.name
      id       = agent.id
      identity = agent.identity
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
