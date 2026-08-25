# =============================================================================
# main.tf — org → templates → projects → delegate → connectors → discovery
# =============================================================================
# One apply creates all Harness workshop resources. Names come from variables.tf
# (TF_VAR_*). Cluster/namespaces default to infrastructure remote state.
#
# terraform init && terraform apply
# terraform output
#
# Docs:
#   https://registry.terraform.io/providers/harness/harness/latest/docs
#   https://developer.harness.io/docs/resilience-testing/platform-features/terraform-onboarding

terraform {
  required_version = ">= 1.5.0"

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
      version = "~> 2.17"
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

# HARNESS_ACCOUNT_ID and HARNESS_PLATFORM_API_KEY must be set in the environment.
provider "harness" {
  endpoint = var.harness_gateway_endpoint
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
  kubernetes {
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
}

data "terraform_remote_state" "infra" {
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

data "harness_platform_template" "k8s" {
  count = var.create_connector_templates ? 0 : 1

  identifier = local.k8s_template_id
  version    = var.template_version
  org_id     = local.org_id
}

data "harness_platform_template" "aws" {
  count = var.create_connector_templates ? 0 : 1

  identifier = local.aws_template_id
  version    = var.template_version
  org_id     = local.org_id
}

data "harness_platform_template" "prometheus" {
  count = var.create_connector_templates || !var.create_prometheus_connectors ? 0 : 1

  identifier = local.prometheus_template_id
  version    = var.template_version
  org_id     = local.org_id
}

locals {
  prefix_id = replace(var.resource_prefix, "-", "_")
  org_id    = var.org_id
  org_name  = var.org_name != "" ? var.org_name : var.org_id
  tags      = var.tags

  generated_namespaces = [for i in range(1, var.namespace_count + 1) : "${var.namespace_prefix}-${i}"]
  namespaces = length(var.namespaces) > 0 ? var.namespaces : coalesce(
    try(data.terraform_remote_state.infra.outputs.namespaces, null),
    local.generated_namespaces,
  )
  cluster_name = var.cluster_name != "" ? var.cluster_name : data.terraform_remote_state.infra.outputs.cluster_name

  delegate_name       = var.delegate_name != "" ? var.delegate_name : "${var.resource_prefix}-workshop-delegate"
  delegate_token_name = var.delegate_token_name != "" ? var.delegate_token_name : "${var.resource_prefix}-workshop-delegate-token"
  delegate_token      = var.decode_delegate_token ? base64decode(harness_platform_delegatetoken.this.value) : harness_platform_delegatetoken.this.value

  k8s_template_id          = var.k8s_template_id != "" ? var.k8s_template_id : "${local.prefix_id}_k8s_inherit_delegate"
  k8s_template_name        = var.k8s_template_name != "" ? var.k8s_template_name : local.k8s_template_id
  aws_template_id          = var.aws_template_id != "" ? var.aws_template_id : "${local.prefix_id}_aws_inherit_delegate"
  aws_template_name        = var.aws_template_name != "" ? var.aws_template_name : local.aws_template_id
  prometheus_template_id   = var.prometheus_template_id != "" ? var.prometheus_template_id : "${local.prefix_id}_prometheus"
  prometheus_template_name = var.prometheus_template_name != "" ? var.prometheus_template_name : local.prometheus_template_id

  k8s_connector_id       = var.k8s_connector_id != "" ? var.k8s_connector_id : "${local.prefix_id}_eks"
  k8s_connector_name     = var.k8s_connector_name != "" ? var.k8s_connector_name : local.k8s_connector_id
  k8s_connector_ref      = "org.${local.k8s_connector_id}"
  aws_connector_id       = var.aws_connector_id != "" ? var.aws_connector_id : "${local.prefix_id}_aws"
  aws_connector_name     = var.aws_connector_name != "" ? var.aws_connector_name : local.aws_connector_id
  aws_connector_ref      = "org.${local.aws_connector_id}"
  prometheus_id_prefix   = var.prometheus_connector_id_prefix != "" ? var.prometheus_connector_id_prefix : "${local.prefix_id}_prometheus"
  prometheus_name_prefix = var.prometheus_connector_name_prefix != "" ? var.prometheus_connector_name_prefix : "${var.resource_prefix}-prometheus"

  environment_id        = var.environment_id != "" ? var.environment_id : local.prefix_id
  environment_name      = var.environment_name != "" ? var.environment_name : local.environment_id
  infra_id              = var.infra_id != "" ? var.infra_id : "${local.prefix_id}_k8s"
  infra_name            = var.infra_name != "" ? var.infra_name : local.infra_id
  discovery_name_prefix = var.discovery_agent_name_prefix != "" ? var.discovery_agent_name_prefix : "${var.resource_prefix}-discovery"
  chaos_name_prefix     = var.chaos_infra_name_prefix != "" ? var.chaos_infra_name_prefix : "${var.resource_prefix}-chaos"

  projects = {
    for ns in local.namespaces : ns => {
      namespace  = ns
      identifier = coalesce(try(var.project_overrides[ns].identifier, null), var.project_identifier_prefix != "" ? "${var.project_identifier_prefix}_${replace(ns, "-", "_")}" : replace(ns, "-", "_"))
      name       = coalesce(try(var.project_overrides[ns].name, null), var.project_name_prefix != "" ? "${var.project_name_prefix}-${ns}" : ns)
    }
  }
}

# -----------------------------------------------------------------------------
# 1. Organization
# -----------------------------------------------------------------------------

resource "harness_platform_organization" "this" {
  identifier  = local.org_id
  name        = local.org_name
  description = var.org_description
  tags        = local.tags
}

# -----------------------------------------------------------------------------
# 2. Org Connector templates (one-time spec; instances are created below)
# -----------------------------------------------------------------------------

resource "harness_platform_template" "k8s" {
  count = var.create_connector_templates ? 1 : 0

  identifier = local.k8s_template_id
  name       = local.k8s_template_name
  org_id     = harness_platform_organization.this.identifier
  version    = var.template_version
  is_stable  = true
  comments   = "HPB workshop Kubernetes connector template (InheritFromDelegate)"
  tags       = local.tags

  template_yaml = <<-EOT
template:
  name: ${local.k8s_template_name}
  identifier: ${local.k8s_template_id}
  versionLabel: ${var.template_version}
  type: Connector
  orgIdentifier: ${harness_platform_organization.this.identifier}
  tags: {}
  spec:
    type: K8sCluster
    spec:
      credential:
        type: InheritFromDelegate
        spec:
          delegateSelectors: <+input>
  EOT
}

resource "harness_platform_template" "aws" {
  count = var.create_connector_templates ? 1 : 0

  identifier = local.aws_template_id
  name       = local.aws_template_name
  org_id     = harness_platform_organization.this.identifier
  version    = var.template_version
  is_stable  = true
  comments   = "HPB workshop AWS connector template (InheritFromDelegate)"
  tags       = local.tags

  template_yaml = <<-EOT
template:
  name: ${local.aws_template_name}
  identifier: ${local.aws_template_id}
  versionLabel: ${var.template_version}
  type: Connector
  orgIdentifier: ${harness_platform_organization.this.identifier}
  tags: {}
  spec:
    type: Aws
    spec:
      credential:
        type: InheritFromDelegate
        spec:
          delegateSelectors: <+input>
          region: <+input>
      executeOnDelegate: true
  EOT
}

resource "harness_platform_template" "prometheus" {
  count = var.create_connector_templates ? 1 : 0

  identifier = local.prometheus_template_id
  name       = local.prometheus_template_name
  org_id     = harness_platform_organization.this.identifier
  version    = var.template_version
  is_stable  = true
  comments   = "HPB workshop Prometheus connector template"
  tags       = local.tags

  template_yaml = <<-EOT
template:
  name: ${local.prometheus_template_name}
  identifier: ${local.prometheus_template_id}
  versionLabel: ${var.template_version}
  type: Connector
  orgIdentifier: ${harness_platform_organization.this.identifier}
  tags: {}
  spec:
    type: Prometheus
    spec:
      url: <+input>
      delegateSelectors: <+input>
  EOT
}

# -----------------------------------------------------------------------------
# 3. One project per namespace
# -----------------------------------------------------------------------------

resource "harness_platform_project" "this" {
  for_each = local.projects

  identifier  = each.value.identifier
  name        = each.value.name
  org_id      = harness_platform_organization.this.identifier
  description = "HPB chaos workshop project targeting Kubernetes namespace ${each.value.namespace}"
  color       = var.project_color
  tags        = concat(local.tags, ["namespace:${each.value.namespace}"])
}

# -----------------------------------------------------------------------------
# 4. Delegate in the workshop cluster
# -----------------------------------------------------------------------------

resource "harness_platform_delegatetoken" "this" {
  name       = local.delegate_token_name
  account_id = var.account_id
  org_id     = harness_platform_organization.this.identifier
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
  wait             = true
  wait_for_jobs    = false
  atomic           = true
  timeout          = 600
  cleanup_on_fail  = true

  set {
    name  = "delegateName"
    value = local.delegate_name
  }
  set {
    name  = "accountId"
    value = var.account_id
  }
  set {
    name  = "managerEndpoint"
    value = var.manager_endpoint
  }
  set {
    name  = "replicas"
    value = tostring(var.delegate_replicas)
  }
  set {
    name  = "nextGen"
    value = "true"
  }
  set {
    name  = "k8sPermissionsType"
    value = "CLUSTER_ADMIN"
  }
  set {
    name  = "upgrader.enabled"
    value = "true"
  }
  set_sensitive {
    name  = "delegateToken"
    value = local.delegate_token
  }

  depends_on = [
    harness_platform_delegatetoken.this,
    kubernetes_namespace_v1.delegate,
  ]
}

resource "time_sleep" "delegate_register" {
  create_duration = var.delegate_register_wait
  depends_on      = [helm_release.delegate]
}

# -----------------------------------------------------------------------------
# 5. Org connectors (spec matches the templates; native resources fill <+input>)
# -----------------------------------------------------------------------------

resource "harness_platform_connector_kubernetes" "eks" {
  identifier  = local.k8s_connector_id
  name        = local.k8s_connector_name
  org_id      = harness_platform_organization.this.identifier
  description = "Org Kubernetes connector. Spec matches template ${local.k8s_template_id}:${var.template_version}."
  tags        = concat(local.tags, ["template:${local.k8s_template_id}"])

  inherit_from_delegate {
    delegate_selectors = [local.delegate_name]
  }

  depends_on = [
    harness_platform_template.k8s,
    data.harness_platform_template.k8s,
    time_sleep.delegate_register,
  ]
}

resource "harness_platform_connector_aws" "eks" {
  count = var.create_aws_connector ? 1 : 0

  identifier          = local.aws_connector_id
  name                = local.aws_connector_name
  org_id              = harness_platform_organization.this.identifier
  description         = "Org AWS connector. Spec matches template ${local.aws_template_id}:${var.template_version}."
  tags                = concat(local.tags, ["template:${local.aws_template_id}"])
  execute_on_delegate = true

  inherit_from_delegate {
    delegate_selectors = [local.delegate_name]
    region             = var.aws_region
  }

  depends_on = [
    harness_platform_template.aws,
    data.harness_platform_template.aws,
    time_sleep.delegate_register,
  ]
}

resource "harness_platform_connector_prometheus" "namespace" {
  for_each = var.create_prometheus_connectors ? toset(local.namespaces) : toset([])

  identifier         = "${local.prometheus_id_prefix}_${replace(each.value, "-", "_")}"
  name               = "${local.prometheus_name_prefix}-${each.value}"
  org_id             = harness_platform_organization.this.identifier
  description        = "Prometheus in namespace ${each.value}. Spec matches template ${local.prometheus_template_id}:${var.template_version}."
  tags               = concat(local.tags, ["template:${local.prometheus_template_id}", "namespace:${each.value}"])
  url                = "http://prometheus.${each.value}.svc.cluster.local:${var.prometheus_port}"
  delegate_selectors = [local.delegate_name]

  depends_on = [
    harness_platform_template.prometheus,
    data.harness_platform_template.prometheus,
    time_sleep.delegate_register,
  ]
}

# -----------------------------------------------------------------------------
# 6. Per project: environment, infra, discovery agent, chaos infra v2
# -----------------------------------------------------------------------------

resource "harness_platform_environment" "this" {
  for_each = local.projects

  identifier   = local.environment_id
  name         = local.environment_name
  org_id       = harness_platform_organization.this.identifier
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
  org_id          = harness_platform_organization.this.identifier
  project_id      = harness_platform_project.this[each.key].identifier
  env_id          = harness_platform_environment.this[each.key].identifier
  type            = "KubernetesDirect"
  deployment_type = "Kubernetes"
  force_delete    = true
  tags            = concat(local.tags, ["namespace:${each.value.namespace}"])

  yaml = <<-EOT
infrastructureDefinition:
  name: ${local.infra_name}
  identifier: ${local.infra_id}
  orgIdentifier: ${harness_platform_organization.this.identifier}
  projectIdentifier: ${harness_platform_project.this[each.key].identifier}
  environmentRef: ${local.environment_id}
  description: HPB workshop Kubernetes infrastructure for ${each.value.namespace}
  tags:
    workshop: "true"
    namespace: ${each.value.namespace}
  deploymentType: Kubernetes
  type: KubernetesDirect
  spec:
    connectorRef: ${local.k8s_connector_ref}
    namespace: ${each.value.namespace}
    releaseName: release-<+INFRA_KEY>
  allowSimultaneousDeployments: true
  EOT

  depends_on = [
    harness_platform_environment.this,
    harness_platform_connector_kubernetes.eks,
  ]
}

resource "harness_service_discovery_agent" "this" {
  for_each = local.projects

  name                   = "${local.discovery_name_prefix}-${each.value.namespace}"
  org_identifier         = harness_platform_organization.this.identifier
  project_identifier     = harness_platform_project.this[each.key].identifier
  environment_identifier = harness_platform_environment.this[each.key].id
  infra_identifier       = harness_platform_infrastructure.this[each.key].id
  installation_type      = var.discovery_installation_type

  config {
    kubernetes {
      namespace = var.discovery_install_namespace != "" ? var.discovery_install_namespace : each.value.namespace
    }
    data {
      observed_namespaces      = [each.value.namespace]
      blacklisted_namespaces   = ["kube-system", "kube-public", var.delegate_namespace]
      collection_window_in_min = 10
    }
  }

  depends_on = [harness_platform_infrastructure.this]
}

resource "harness_chaos_infrastructure_v2" "this" {
  for_each = local.projects

  org_id         = harness_platform_organization.this.identifier
  project_id     = harness_platform_project.this[each.key].identifier
  environment_id = harness_platform_environment.this[each.key].id
  infra_id       = harness_platform_infrastructure.this[each.key].id
  name           = "${local.chaos_name_prefix}-${each.value.namespace}"
  description    = "DDCR chaos infrastructure for namespace ${each.value.namespace}"

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
        echo "No chaos install command for ${each.value.namespace}; DDCR will use ${local.k8s_connector_ref}"
        exit 0
      fi
      aws eks update-kubeconfig --region ${var.aws_region} --name ${local.cluster_name} --kubeconfig /tmp/hpb-eks.kubeconfig
      export KUBECONFIG=/tmp/hpb-eks.kubeconfig
      echo "Running chaos install command for ${each.value.namespace}"
      bash -lc "$CMD"
    EOT
  }

  depends_on = [harness_chaos_infrastructure_v2.this]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "org_id" {
  value = harness_platform_organization.this.identifier
}

output "namespaces" {
  value = local.namespaces
}

output "projects" {
  value = {
    for ns, project in harness_platform_project.this : ns => {
      identifier = project.identifier
      name       = project.name
    }
  }
}

output "delegate_name" {
  value = local.delegate_name
}

output "k8s_connector_ref" {
  value = local.k8s_connector_ref
}

output "aws_connector_ref" {
  value = var.create_aws_connector ? local.aws_connector_ref : null
}

output "prometheus_connector_refs" {
  value = {
    for ns, connector in harness_platform_connector_prometheus.namespace :
    ns => "org.${connector.identifier}"
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
