# Harness Payment Bank — workshop Harness resources

This Terraform root is the **second** workshop apply. After EKS and the banking apps exist (`../infrastructure`), one `terraform apply` registers Harness so each namespace can run discovery and chaos.

It does **not** create VPC, EKS, or application pods. It talks to the Harness API and installs a delegate into the cluster that `infrastructure/` already created.

```text
harness-chaos-demo/
└── harness-payment-bank/
    ├── infrastructure/      # first apply: EKS + banking-1 … N
    └── harness-resources/   # this directory: Harness org → chaos
        ├── main.tf
        ├── variables.tf
        └── README.md
```

State is separate from EKS:

| Root | S3 key |
| --- | --- |
| `infrastructure/` | `hpb-eks/terraform.tfstate` |
| `harness-resources/` | `hpb-harness/terraform.tfstate` |

Same bucket (`hpb-demo-tfstate-naren`) and lock table (`hpb-demo-tf-lock`). Destroy here does **not** destroy the cluster.

## What this apply is for

Harness needs a chain from account down to “inject faults in `banking-1`”:

1. An **organization** (workshop container).
2. **Projects** — one per Kubernetes namespace so each attendee has their own space.
3. A **delegate** running **on** `hpb-eks` — the worker that talks to Kubernetes and AWS from inside the cluster.
4. **Connectors** that tell Harness “use that delegate for this cluster / AWS / Prometheus.”
5. Per project: an **environment**, a **Kubernetes infrastructure definition** (which namespace), a **discovery agent** (map services), and **chaos infra v2** (run experiments).

Connector **templates** are created in the same apply as a reusable spec. Terraform still creates connector **instances** with native resources, because the Harness Terraform provider does not accept `templateRef` on Kubernetes / AWS / Prometheus connectors. The instances fill the template’s `<+input>` fields (delegate selector, region, Prometheus URL).

Experiments are **not** created here. After discovery maps services, build experiments in the UI.

## Prerequisites

- `../infrastructure` already applied: cluster `hpb-eks` (or your override) and namespaces `banking-1` … `N`.
- AWS credentials that can `eks get-token` for that cluster (`helm` / `kubectl` install the delegate).
- `HARNESS_ACCOUNT_ID` and `HARNESS_PLATFORM_API_KEY` (Harness PAT / service account, not AWS keys).
- `TF_VAR_account_id` set to the same account ID (Terraform variable; the provider also reads `HARNESS_ACCOUNT_ID`).
- `terraform` `>= 1.5`, `aws`, `helm`, `kubectl`.

Namespaces and cluster name are read from `hpb-eks/terraform.tfstate`. Override with `TF_VAR_namespaces` / `TF_VAR_cluster_name` if that state is missing.

## How apply creates resources (order)

Terraform in `main.tf` is one graph. Dependencies force this order. Names below are the **defaults** (`resource_prefix=hpb`, four namespaces from infra state).

```text
1. Read infrastructure remote state → cluster name + namespaces
2. Organization
3. Connector templates (org)
4. Projects (one per namespace)
5. Delegate token (Harness) + namespace + Helm release (EKS)
6. Wait 60s so Harness marks the delegate CONNECTED
7. Org connectors (K8s, AWS, Prometheus) — they select the delegate
8. Per project, in order:
     environment
       → Kubernetes infrastructure definition (points at org K8s connector + namespace)
         → discovery agent (installs via that connector)
           → chaos infrastructure v2 (links the discovery agent)
             → optional kubectl of Harness’s install_command
```

Providers:

| Provider | Used for |
| --- | --- |
| `harness` | Org, templates, projects, token, connectors, env, infra, discovery, chaos |
| `aws` | Look up EKS API endpoint (`data.aws_eks_cluster`) |
| `kubernetes` / `helm` | Create `harness-delegate-ng` and install `harness-delegate-ng` chart |
| `time` | Wait after Helm Ready |
| `null` | Run chaos `install_command` if Harness returns one |

Kubernetes and Helm authenticate with `aws eks get-token` at apply time (not a stored kubeconfig).

## Default names (full catalog)

Empty name variables fall back to `resource_prefix` (`hpb`). Hyphens in Kubernetes names become underscores in Harness identifiers.

### Account / org (once)

| Resource | Terraform | Identifier | Display name | Scope |
| --- | --- | --- | --- | --- |
| Organization | `harness_platform_organization.this` | `workshop` | `workshop` | account |
| K8s connector template | `harness_platform_template.k8s` | `hpb_k8s_inherit_delegate` | same | org `workshop`, version `v1` |
| AWS connector template | `harness_platform_template.aws` | `hpb_aws_inherit_delegate` | same | org, `v1` |
| Prometheus connector template | `harness_platform_template.prometheus` | `hpb_prometheus` | same | org, `v1` |
| Delegate token | `harness_platform_delegatetoken.this` | name `hpb-workshop-delegate-token` | — | org |
| Kubernetes connector | `harness_platform_connector_kubernetes.eks` | `hpb_eks` | `hpb_eks` | org. Ref from projects: `org.hpb_eks` |
| AWS connector | `harness_platform_connector_aws.eks` | `hpb_aws` | `hpb_aws` | org. Ref: `org.hpb_aws` |

`org_name` empty means display name = `org_id`.

### On the EKS cluster (once)

| Resource | Terraform | Name |
| --- | --- | --- |
| Namespace | `kubernetes_namespace_v1.delegate` | `harness-delegate-ng` |
| Helm release / delegate | `helm_release.delegate` | `hpb-workshop-delegate` (chart `harness-delegate-ng`) |

The delegate registers with Harness using the org token. Connectors and discovery/chaos tasks select it by name `hpb-workshop-delegate`.

### Per Kubernetes namespace (defaults: `banking-1` … `banking-4`)

Same pattern for each namespace. Example for `banking-1`:

| Resource | Terraform | Identifier / name | Lives in |
| --- | --- | --- | --- |
| Project | `harness_platform_project.this["banking-1"]` | id `banking_1`, name `banking-1` | org `workshop` |
| Prometheus connector | `harness_platform_connector_prometheus.namespace["banking-1"]` | id `hpb_prometheus_banking_1`, name `hpb-prometheus-banking-1` | org. Ref: `org.hpb_prometheus_banking_1`. URL `http://prometheus.banking-1.svc.cluster.local:9090` |
| Environment | `harness_platform_environment.this["banking-1"]` | `hpb` / `hpb`, type `PreProduction` | project `banking_1` |
| K8s infra definition | `harness_platform_infrastructure.this["banking-1"]` | `hpb_k8s` / `hpb_k8s` | project `banking_1`, env `hpb`. Points at `org.hpb_eks` and namespace `banking-1` |
| Discovery agent | `harness_service_discovery_agent.this["banking-1"]` | `hpb-discovery-banking-1` | project `banking_1`. Observes `banking-1`. Install type `CONNECTOR` |
| Chaos infra v2 | `harness_chaos_infrastructure_v2.this["banking-1"]` | `hpb-chaos-banking-1` | project `banking_1`. Type `KubernetesV2`, scope `NAMESPACE`, SA `harness-chaos` in `banking-1` |

Repeat for `banking-2` → project `banking_2`, Prometheus `hpb_prometheus_banking_2`, discovery `hpb-discovery-banking-2`, chaos `hpb-chaos-banking-2`. Environment and infra **identifiers** stay `hpb` and `hpb_k8s` because they are unique **per project**, not globally.

With four namespaces, apply creates **four** of each per-project object plus **four** Prometheus connectors.

## How the pieces talk to each other

```text
Harness account
└── org workshop
    ├── templates (spec only; not referenced by templateRef in Terraform)
    ├── delegate token ──► Helm on EKS ──► pod hpb-workshop-delegate
    │                                            ▲
    │                                            │ selector
    ├── connector org.hpb_eks  ──────────────────┤  cluster API via delegate
    ├── connector org.hpb_aws  ──────────────────┤  AWS API via delegate (node/IRSA later)
    └── connector org.hpb_prometheus_banking_N ──┘  scrape in-cluster Prometheus
        │
        └── project banking_N  (one attendee / one K8s namespace)
            ├── environment hpb
            └── infra hpb_k8s
                  spec.connectorRef = org.hpb_eks
                  spec.namespace    = banking-N
                        │
                        ├── discovery hpb-discovery-banking-N
                        │     installation_type = CONNECTOR
                        │     uses env + infra → therefore the org K8s connector
                        │     installs agent, maps services in banking-N
                        │
                        └── chaos hpb-chaos-banking-N
                              same env + infra
                              discovery_agent_id = that discovery agent
                              DDCR / faults stay in namespace banking-N
```

In words:

- **Delegate** is the only worker on the cluster. Nothing else can reach Kubernetes or in-cluster Prometheus until it is CONNECTED.
- **Org Kubernetes connector** (`org.hpb_eks`) is inherit-from-delegate: Harness does not store a kubeconfig; it asks `hpb-workshop-delegate` to run kubectl-equivalent calls. All projects share this one connector.
- **Infrastructure definition** is the binding “this project’s env `hpb` means namespace `banking-N` on that connector.” Discovery and chaos both require env + infra so they inherit that binding.
- **Discovery** (`CONNECTOR`) installs its agent through that same path and watches only its namespace (plus it blacklists `kube-system`, `kube-public`, `harness-delegate-ng`).
- **Chaos v2** (`KubernetesV2` / DDCR) is scoped to that namespace and is wired to **that project’s** discovery agent so experiment UI can pick discovered services.
- **Prometheus connectors** are org-level, one URL per namespace. They are created for later SLO/probe work; chaos infra does not reference them in this apply.
- **AWS connector** is org-level inherit-from-delegate. It is not required for discovery/chaos v2 in this graph; it is there for AWS faults or later pipeline steps that run on this delegate.

Shared vs copied:

| Shared across all projects | Copied once per namespace |
| --- | --- |
| Org, templates, delegate, `org.hpb_eks`, `org.hpb_aws` | Project, Prometheus connector, env `hpb`, infra `hpb_k8s`, discovery, chaos |

## Apply

```bash
export HARNESS_ACCOUNT_ID="..."
export HARNESS_PLATFORM_API_KEY="..."
export TF_VAR_account_id="$HARNESS_ACCOUNT_ID"

# only if Account Settings → Overview is not https://app.harness.io
# export TF_VAR_manager_endpoint="https://..."

cd harness-payment-bank/harness-resources
terraform init
terraform apply
```

Typical create time: a few minutes after the cluster already exists (Helm wait + 60s registration).

When it finishes:

```bash
terraform output
```

You should see `org_id`, `projects`, `delegate_name`, `k8s_connector_ref`, discovery agent ids, and chaos infra status.

In Harness UI: **Account → Organizations → workshop**. Open project `banking-1`. Environment `hpb` should list infra `hpb_k8s`. Discovery and chaos should show agents for that namespace.

On the cluster:

```bash
kubectl get pods -n harness-delegate-ng
kubectl get pods -n banking-1 | grep -E 'discovery|chaos' || true
```

## Destroy

```bash
cd harness-payment-bank/harness-resources
terraform destroy
```

Removes the org contents this state owns (projects, connectors, delegate Helm release, etc.). It does **not** destroy `hpb-eks` or the banking apps.

If org `workshop` already exists outside this state:

```bash
terraform import harness_platform_organization.this workshop
```

If connector templates already exist in the org: import them, or skip create with `TF_VAR_create_connector_templates=false` (Terraform then looks them up by id).

## Inputs (optional)

Only export a variable when you want to override a default. Empty exports can blank out names.

| Variable | Default | Effect |
| --- | --- | --- |
| `resource_prefix` | `hpb` | Prefix for generated connector, delegate, discovery, chaos names |
| `org_id` / `org_name` | `workshop` / empty | Org identifier; empty name uses `org_id` |
| `cluster_name` | from infra state | EKS cluster for Helm |
| `namespaces` | from infra state | One project per entry |
| `delegate_name` | `hpb-workshop-delegate` | Helm release and connector selector |
| `k8s_connector_id` | `hpb_eks` | Org connector; projects use `org.<id>` |
| `environment_id` | `hpb` | Same id in every project |
| `infra_id` | `hpb_k8s` | Same id in every project |
| `create_aws_connector` | `true` | Set `false` to skip `org.hpb_aws` |
| `create_prometheus_connectors` | `true` | One org Prometheus connector per namespace |
| `apply_chaos_install_command` | `true` | Run Harness `install_command` via kubectl if non-empty |

Examples:

```bash
export TF_VAR_org_id=workshop
export TF_VAR_org_name="Chaos Workshop"
export TF_VAR_resource_prefix=hpb
export TF_VAR_delegate_name=hpb-workshop-delegate
export TF_VAR_k8s_connector_id=hpb_eks
export TF_VAR_project_identifier_prefix=ws   # projects become ws_banking_1
export TF_VAR_discovery_agent_name_prefix=hpb-discovery
export TF_VAR_chaos_infra_name_prefix=hpb-chaos
```

Per-namespace project names (do not commit secrets; `terraform.tfvars` is optional and local):

```hcl
project_overrides = {
  "banking-1" = { identifier = "team_alpha", name = "Team Alpha" }
}
```

## Pipeline shape

Keep plan/apply in this repo. Recommended stages:

1. **Plan** — checkout, Harness + AWS auth, `terraform init`, `terraform plan -out=tfplan` in this directory
2. **Approve**
3. **Apply** — `terraform apply tfplan`

Working directory:

```text
harness-payment-bank/harness-resources
```

The runner needs `terraform`, `aws`, `helm`, and `kubectl`. This apply currently uses AWS to talk to EKS for Helm; it does not create the cluster. After the workshop delegate is on EKS with workload identity, later **infrastructure** applies can run on this delegate without AWS access keys (see the IRSA notes in the workshop plan). `HARNESS_PLATFORM_API_KEY` is still required for the Harness provider.

## Notes

- Keep `main.tf` and `variables.tf` as the only Terraform language files.
- Discovery install type is `CONNECTOR`: agents are installed through `org.hpb_eks`, not a hand-run Helm chart in this root.
- Chaos type `KubernetesV2` is DDCR. Scope `NAMESPACE` so `banking-1` cannot target `banking-2`.
- Tags on created objects include `workshop:true`, `project:hpb`, `managedby:terraform`.
