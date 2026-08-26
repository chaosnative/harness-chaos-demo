# Harness Payment Bank — workshop Harness resources

End-to-end map (pipeline + AWS + PAT + `team-N` vs `banking-N`): [`../README.md`](../README.md).

This root is the **second** apply. After EKS exists, it creates org `workshop`, one Harness project **`team-N` per namespace `banking-N`**, a delegate on the cluster, per-project K8s/Prometheus connectors, discovery, and chaos infra.

It does **not** create VPC, EKS, or application pods.

```text
harness-payment-bank/
├── README.md           # start here
├── infrastructure/     # EKS + banking-N
└── harness-resources/  # this directory
```

State key: `hpb-harness/terraform.tfstate`. Destroy here does **not** destroy the cluster.

## What apply creates

1. Organization `workshop`.
2. Connector templates (org).
3. Projects: namespace `banking-1` → project id `team_1`, name `team-1`.
4. Delegate on `hpb-eks`.
5. Optional org AWS connector. **Per project:** K8s connector `hpb_eks`, Prometheus, env, infra (namespace still `banking-N`), discovery, chaos v2.

Experiments: import from a template in the UI after apply.

PAT must be from the **same account** as `TF_VAR_account_id` (see parent README).

## How apply creates resources (order)

```text
1. Read infrastructure remote state → cluster name + namespaces banking-N
2. Organization
3. Connector templates (org)
4. Projects team-N (one per namespace)
5. Delegate token + Helm on EKS; wait 60s
6. Org AWS connector (optional)
7. Per project:
     K8s connector + Prometheus
     → environment → infra (connector hpb_eks, namespace banking-N)
       → discovery → chaos v2
```

Kubernetes / Helm use `aws eks get-token` at apply time.

## Default names (full catalog)

Empty name variables fall back to `resource_prefix` (`hpb`).

### Account / org (once)

| Resource | Terraform | Identifier | Display name | Scope |
| --- | --- | --- | --- | --- |
| Organization | `harness_platform_organization.this` | `workshop` | `workshop` | account |
| K8s connector template | `harness_platform_template.k8s` | `hpb_k8s_inherit_delegate` | same | org `workshop`, version `v1` |
| AWS connector template | `harness_platform_template.aws` | `hpb_aws_inherit_delegate` | same | org, `v1` |
| Prometheus connector template | `harness_platform_template.prometheus` | `hpb_prometheus` | same | org, `v1` |
| Delegate token | `harness_platform_delegatetoken.this` | name `hpb-workshop-delegate-token` | — | org |
| AWS connector | `harness_platform_connector_aws.eks` | `hpb_aws` | `hpb_aws` | org. Ref: `org.hpb_aws` |

### On the EKS cluster (once)

| Resource | Terraform | Name |
| --- | --- | --- |
| Namespace | `kubernetes_namespace_v1.delegate` | `harness-delegate-ng` |
| Helm release / delegate | `helm_release.delegate` | `hpb-workshop-delegate` |

### Per namespace (example `banking-1` → Harness `team-1`)

Terraform `for_each` key is still the **namespace** (`"banking-1"`).

| Resource | Identifier / name | Lives in |
| --- | --- | --- |
| Project | id `team_1`, name `team-1` | org `workshop` |
| K8s connector | `hpb_eks` | **project** `team_1` (not org) |
| Prometheus | id `hpb_prometheus_team_1`, name `hpb-prometheus-team-1` | project `team_1`. URL `http://prometheus.banking-1.svc.cluster.local:9090` |
| Environment | `hpb` | project `team_1` |
| K8s infra | `hpb_k8s` | project `team_1`. `connectorRef: hpb_eks`, namespace `banking-1` |
| Discovery | `hpb-discovery-team-1` | observes `banking-1` |
| Chaos infra v2 | `hpb-chaos-team-1` | SA `harness-chaos` in `banking-1` |

`banking-2` → project `team_2` / `team-2`. Env and infra ids stay `hpb` / `hpb_k8s` (unique per project).

## How the pieces talk to each other

```text
org workshop
├── templates
├── delegate hpb-workshop-delegate on EKS
├── org.hpb_aws (optional)
└── project team-N
    ├── k8s connector hpb_eks ──► delegate ──► namespace banking-N
    ├── prometheus ──► prometheus.banking-N
    ├── env hpb → infra hpb_k8s (namespace banking-N)
    ├── discovery hpb-discovery-team-N
    └── chaos hpb-chaos-team-N
```

| Shared (org) | One copy per team |
| --- | --- |
| Org, templates, delegate, optional AWS connector | Project `team-N`, K8s connector, Prometheus, env, infra, discovery, chaos |

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

You should see `org_id`, `projects` (namespace → `team_N`), `delegate_name`, `k8s_connector_refs`, discovery agent ids, and chaos infra status.

In Harness UI: **Account → Organizations → workshop**. Open project **`team-1`**. Environment `hpb` should list infra `hpb_k8s` for namespace `banking-1`.

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
| `k8s_connector_id` | `hpb_eks` | Same id **inside each project** |
| `environment_id` | `hpb` | Same id in every project |
| `infra_id` | `hpb_k8s` | Same id in every project |
| `project_identifier_prefix` | `team` | Project ids `team_1` … from `banking-1` … |
| `create_aws_connector` | `true` | Set `false` to skip `org.hpb_aws` |
| `create_prometheus_connectors` | `true` | One **project** Prometheus connector per team |
| `apply_chaos_install_command` | `true` | Run Harness `install_command` via kubectl if non-empty |

Examples:

```bash
export TF_VAR_org_id=workshop
export TF_VAR_org_name="Chaos Workshop"
export TF_VAR_resource_prefix=hpb
export TF_VAR_delegate_name=hpb-workshop-delegate
export TF_VAR_k8s_connector_id=hpb_eks
export TF_VAR_project_identifier_prefix=team   # default; team_1 for banking-1
export TF_VAR_discovery_agent_name_prefix=hpb-discovery
export TF_VAR_chaos_infra_name_prefix=hpb-chaos
```

Per-namespace project names (do not commit secrets; `terraform.tfvars` is optional and local):

```hcl
project_overrides = {
  "banking-1" = { identifier = "team_alpha", name = "Team Alpha" }
}
```

## If apply fails

This is **not** like `infrastructure/`. A failed EKS apply leaves AWS objects that block the next create, so that root rolls back with destroy. A failed harness-resources apply usually leaves a **partial Terraform state** plus some objects already in Harness. **Re-run apply.** Do not destroy unless you want a clean workshop org.

```bash
cd harness-payment-bank/harness-resources
terraform state list          # what Terraform already owns
terraform apply               # continues from state
```

`terraform apply` is incremental. Resources already in state are left alone. Missing ones are created.

### Do not auto-destroy on failure

Destroying this root deletes org `workshop`, projects, connectors, and the delegate Helm release. It does **not** delete EKS. That is the right cleanup when you want to start the Harness side from zero — not the default reaction to a timeout.

### Common errors

| Error you see | What it means | What to do |
| --- | --- | --- |
| `Error acquiring the state lock` | Another apply/pipeline still running, or a crash left the DynamoDB lock | Wait, or `terraform force-unlock <LOCK_ID>` only if you are sure nothing else is applying |
| Remote state `hpb-eks/terraform.tfstate` missing / no `namespaces` | Infrastructure apply never finished | Apply `../infrastructure` first, or set `TF_VAR_cluster_name` and `TF_VAR_namespaces` |
| `Unauthorized` / `eks get-token` / Helm Kubernetes auth | AWS session on the runner expired (SSO token) | Refresh AWS creds (or secrets), re-run apply. Helm/delegate already in state are reused |
| Delegate pods not Ready / connectors fail after 60s | Helm installed but Harness has not marked the delegate CONNECTED | `kubectl get pods -n harness-delegate-ng`. Fix image/token/`TF_VAR_manager_endpoint`. Then `export TF_VAR_delegate_register_wait=180s` and apply again |
| `DUPLICATE_IDENTIFIER` / already exists | Object is in Harness but **not** in this Terraform state (apply died after the API create, or it was created in the UI) | Import it (below), or delete that object in Harness and apply again |
| Template already exists in org `workshop` | Templates were created outside this state | `terraform import` each template, **or** `TF_VAR_create_connector_templates=false` and apply |
| Helm `hpb-workshop-delegate` already exists in `harness-delegate-ng` | Previous install not in state | `helm uninstall hpb-workshop-delegate -n harness-delegate-ng` **or** import `helm_release.delegate`, then apply |
| `401 Unauthorized` on `harness_platform_organization` | PAT is wrong, expired, or from a **different account** than `TF_VAR_account_id` | Token from My Profile in the **workshop** account; see [`../README.md`](../README.md) |
| Discovery / chaos create 4xx | Delegate or **project** K8s connector `hpb_eks` not working yet | Confirm connector test in project `team-1`, then apply again |

### Import (object exists, not in state)

Import IDs are `org` / `org/project` / `org/project/id`. After import, `terraform apply` should show no recreate for that resource.

```bash
# org
terraform import harness_platform_organization.this workshop

# project (for_each key is the Kubernetes namespace; id is team_1)
terraform import 'harness_platform_project.this["banking-1"]' workshop/team_1

# project K8s connector (format: org/project/connector)
terraform import 'harness_platform_connector_kubernetes.eks["banking-1"]' workshop/team_1/hpb_eks
terraform import 'harness_platform_connector_aws.eks[0]' workshop/hpb_aws
terraform import 'harness_platform_connector_prometheus.namespace["banking-1"]' workshop/team_1/hpb_prometheus_team_1

# templates (or TF_VAR_create_connector_templates=false)
terraform import 'harness_platform_template.k8s[0]' workshop/hpb_k8s_inherit_delegate/v1
terraform import 'harness_platform_template.aws[0]' workshop/hpb_aws_inherit_delegate/v1
terraform import 'harness_platform_template.prometheus[0]' workshop/hpb_prometheus/v1

# delegate on the cluster
terraform import helm_release.delegate harness-delegate-ng/hpb-workshop-delegate
```

If import ID format is rejected, check the resource page on the [Harness Terraform provider](https://registry.terraform.io/providers/harness/harness/latest/docs). Environment / infra / discovery / chaos import IDs include org, project, and the resource id — deleting the leftover in the UI and re-applying is often faster than hunting the ID.

### Clean slate (workshop Harness side only)

```bash
cd harness-payment-bank/harness-resources
terraform destroy -auto-approve   # does not destroy hpb-eks
terraform apply
```

If destroy fails because Harness still has objects that were never in state, delete org `workshop` (or the leftover connector/project) in the UI, `terraform state list` until empty, then apply.

On the cluster after a bad Helm install:

```bash
kubectl get all -n harness-delegate-ng
helm uninstall hpb-workshop-delegate -n harness-delegate-ng
```

## Harness pipeline

Put this in the **same pipeline** as EKS, as the **next stage** after infrastructure Apply succeeds. That is the workshop flow: create the cluster, then register Harness on it.

Do **not** put harness-resources in the same *step* (or same working directory) as EKS apply. Two Terraform roots, two state files. A failure in the new stage must **not** run `infrastructure/apply.sh` or `terraform destroy` on EKS.

```text
Plan EKS → Approve (once) → Apply EKS (infrastructure/)
                          → Apply Harness resources (harness-resources/)
```

Do **not** add a second Plan → Approve → Apply loop. EKS needs a plan and a human gate because it creates a cluster. Harness resources are the next step of that same approved run: one Shell step, `terraform init` then `terraform apply -auto-approve` in `harness-payment-bank/harness-resources`.

If you want a plan in the logs, run `terraform plan` in the **same** stage immediately before apply. Do not wait for another approval in between (SSO tokens die; the plan file does not carry across stages unless you upload it).

Same delegate as EKS (`hpb-demo-delegate`). It **cannot** use `hpb-workshop-delegate` on the first run — that pod is what this stage creates.

Do **not** use native `TerraformPlan` / `TerraformApply` steps here. Those run Terraform in a plugin image that does not include `helm` and `kubectl`. This root needs `terraform`, `aws`, `helm`, and `kubectl` on the delegate (same as EKS).

**If the new stage fails:** in the execution UI, **Retry from last failed stage** (harness-resources only). Do not re-run the whole pipeline from Plan/Apply EKS — especially if EKS Apply uses `apply.sh` destroy-on-failure.

**SSO tokens:** EKS Apply can take 25–40 minutes. If `AWS_SESSION_TOKEN` expires before this stage starts, refresh secrets and retry **this stage only**. That is the one reason to keep a separate pipeline; if your keys last long enough, one pipeline is simpler.

Stage failure strategy for harness-resources: **MarkAsFailure** only. Never `PipelineRollback`, never a failure Shell that destroys `infrastructure/`.

### Secrets and variables

Create or reuse these in that project (or account/org, then reference them):

| Name | Kind | Used as |
| --- | --- | --- |
| `harness_platform_api_key` | Secret (PAT / service account) | `HARNESS_PLATFORM_API_KEY` |
| `aws_access_key_id` | Secret | `AWS_ACCESS_KEY_ID` (until IRSA) |
| `aws_secret_access_key` | Secret | `AWS_SECRET_ACCESS_KEY` |
| `aws_session_token` | Secret (optional; SSO) | `AWS_SESSION_TOKEN` |
| `harness_account_id` | Pipeline variable (string) | `HARNESS_ACCOUNT_ID` and `TF_VAR_account_id` |

The API key is a **Harness** token so Terraform can create org/projects. It is not an AWS key.

Git: same repo connector you already use to checkout `harness-chaos-demo`.

### Stages to add (after EKS Apply)

Working directory for this stage only:

```text
harness-payment-bank/harness-resources
```

Optional extra Approval between EKS Apply and this stage. On failure: **MarkAsFailure**, then retry this stage.

### Stage YAML to paste

Add this stage after EKS Apply. Reuse the same Git clone if the workspace still has the repo; otherwise clone again. Replace secret names if yours differ.

Add pipeline variables `harness_account_id` and (optional) `manager_endpoint` if they are not already on the EKS pipeline. Then append this stage:

```yaml
    - stage:
        name: Apply Harness resources
        identifier: apply_harness_resources
        type: Custom
        spec:
          execution:
            steps:
              - step:
                  type: ShellScript
                  name: Terraform apply harness-resources
                  identifier: tf_apply_harness_resources
                  spec:
                    shell: Bash
                    onDelegate: true
                    source:
                      type: Inline
                      spec:
                        script: |
                          set -euo pipefail
                          cd harness-payment-bank/harness-resources
                          export HARNESS_ACCOUNT_ID="<+pipeline.variables.harness_account_id>"
                          export HARNESS_PLATFORM_API_KEY="<+secrets.getValue("harness_platform_api_key")>"
                          export TF_VAR_account_id="$HARNESS_ACCOUNT_ID"
                          export TF_VAR_manager_endpoint="<+pipeline.variables.manager_endpoint>"
                          export AWS_ACCESS_KEY_ID="<+secrets.getValue("aws_access_key_id")>"
                          export AWS_SECRET_ACCESS_KEY="<+secrets.getValue("aws_secret_access_key")>"
                          export AWS_SESSION_TOKEN="<+secrets.getValue("aws_session_token")>"
                          export AWS_DEFAULT_REGION=us-east-1
                          terraform init -input=false
                          terraform apply -input=false -auto-approve
                    executionTarget: {}
                  timeout: 30m
        delegateSelectors:
          - hpb-demo-delegate
        failureStrategies:
          - onFailure:
              errors:
                - AllErrors
              action:
                type: MarkAsFailure
```

If the EKS stages already cloned the repo into a different path, `cd` to that clone’s `harness-payment-bank/harness-resources`. Skip GitClone here if the workspace still has the checkout from an earlier stage.

After the workshop delegate is CONNECTED, you can later move **infrastructure** plan/apply onto `hpb-workshop-delegate` and drop AWS keys (IRSA). This stage still needs a Harness API key.

## Notes


- Keep `main.tf` and `variables.tf` as the only Terraform language files.
- Discovery install type is `CONNECTOR`: agents are installed through the **project** Kubernetes connector `hpb_eks`, not a hand-run Helm chart in this root.
- Chaos type `KubernetesV2` is DDCR. Scope `NAMESPACE` so `banking-1` cannot target `banking-2`.
- Tags on created objects include `workshop:true`, `project:hpb`, `managedby:terraform`.
