# Harness Payment Bank — end-to-end workshop

This is the internal map of the whole workshop. Read this first. The two Terraform folders are only *how* to build pieces; this file is *what exists, how it connects, and what we learned deploying it*.

Org **PnC** is only a **layout reference** (one org, delegate, one project per team). We do **not** reuse PnC’s account, connectors, hubs, or names. Everything below is created fresh in org `workshop`.

`harness-resources/` Terraform language is **`main.tf` + `variables.tf` only** (other files in that folder are gitignored).

## The three machines (do not mix them)

| # | What | Lives in | Job |
| --- | --- | --- | --- |
| 1 | **Pipeline** | Harness project `PROD` / `CHAOS` (or wherever you saved `harness-payment-bank-demo`) | Runs Terraform. It is a *contractor*, not the workshop. |
| 2 | **AWS cluster** | Amazon (`infrastructure/` → EKS `hpb-eks`) | Real computers. Namespaces `banking-1` … `banking-N` hold the bank app. |
| 3 | **Workshop Harness** | Org `workshop` (`harness-resources/`) | Chaos UI: teams, connectors, discovery, experiments. |

```text
You click Run on the pipeline
        │
        ├─ 1st stage  →  builds (2) AWS cluster + banking-N apps
        └─ 2nd stage  →  builds (3) org workshop + team-N projects
                              │
                              └── delegate pod runs ON cluster (2)
                                  so Harness cloud can touch banking-N
```

Kubernetes names and Harness names are **different on purpose**. PnC uses `team1` / `banking1` (no hyphen/underscore). Workshop uses `team_1` / `team-1` / `banking-1`. Same index. Attendee “team 1” breaks only `banking-1`.

| PnC (reference only) | Workshop (what we create) | Kubernetes on hpb-eks |
| --- | --- | --- |
| org `PnC` / project `team1` | org `workshop` / project `team_1` (name `team-1`) | namespace `banking-1` |
| env `workshop` / agent **DA-banking-1** (id `banking1`), Namespace dropdown **banking-1** | env `hpb` / agent **hpb-discovery-team-1**, Inclusion **banking-1** | namespace `banking-1` |
| org `PnC` / project `team2` | project `team_2` | namespace `banking-2` |

## PAT — which account?

The token in secret `HARNESS_PLATFORM_API_KEY` / `Naren_Harness_Platform_API` must be created in **the same Harness account that owns org `workshop`**.

| Role | Account ID | Host |
| --- | --- | --- |
| **Workshop org, PAT, `TF_VAR_account_id`** | `cTU1lRSWS2SSRV9phKvuOA` | `https://app.harness.io` |
| Pipeline / Git UI (contractor) | `l7B_kbSEQD2wjrM7PShm5w` | git0 / harness0 — **do not** create org `workshop` here |

Pipeline variable `harness_account_id` and `TF_VAR_account_id` must be **`cTU1lRSWS2SSRV9phKvuOA`**, even if the pipeline YAML lives under `PROD` / `CHAOS` of the other account.

Rules:

1. PAT account = `TF_VAR_account_id` = URL account for **Organizations → workshop**. Mismatch → **401 Unauthorized**.
2. Use the **Token** string (`pat.<accountId>.…`), not the API key *name*. Use `HARNESS_PLATFORM_API_KEY` (next-gen), not first-gen `HARNESS_API_KEY`.
3. The pipeline’s home project (`PROD` / `CHAOS`) is not org `workshop`.

## Identifiers (do not invent new ones)

| Thing | Value | Notes |
| --- | --- | --- |
| Org | `workshop` | `prevent_destroy` in Terraform |
| Projects | `team_1` … `team_N` (name `team-N`) | Kubernetes namespace is `banking-N` |
| Delegate Helm release | `hpb-workshop-delegate` | Namespace `harness-delegate-ng` **on hpb-eks** |
| K8s connector (per project) | `hpb_eks` | Underscore OK (Harness ID, not a Helm release name) |
| Environment | `hpb` | |
| CD / chaos infra id | **`hpbk8s`** | Letters+digits only. Display name `hpb-k8s`. Never `hpb_k8s` or `hpb-k8s` as the identifier |
| Discovery in Terraform | `harness_service_discovery_agent.workshop` | Name `hpb-discovery-team-N`. Install in `harness-delegate-ng`, SA `chaos-delegate`, cron `0/15 * * * *`, Inclusion `banking-N`, **network trace off**. Force-replace via `terraform_data.discovery_cluster_scope`. |
| Chaos infra | `hpb-chaos-team-N` | Helm event-watcher name is `event-watcher-hpbk8s` |
| S3 (workshop TF) | bucket `hpb-demo-tfstate-naren`, key `hpb-harness/terraform.tfstate` | Lock table `hpb-demo-tf-lock` |
| Git branch for `harness-resources/` | `automate_workshop` | Stage 1 EKS may still use `main` |
| Stage 2 provisioner id | `hpb_harness_resources` | Never reuse `hpb_infrastructure` |

## What gets created (target layout)

```text
Harness account  <── PAT belongs here (cTU1l…)
└── org workshop
    ├── delegate          hpb-workshop-delegate   (pod on hpb-eks)
    ├── templates         chaos experiment templates (hub; create once in UI if you import via TF)
    └── project team-1    (attendee 1)     namespace banking-1
        ├── k8s connector     hpb_eks
        ├── environment       hpb
        ├── infra             hpbk8s             → hpb_eks, namespace banking-1
        ├── prometheus        hpb-prometheus-team-1  → prometheus.banking-1
        ├── discovery         hpb-discovery-team-1  (ns harness-delegate-ng, Inclusion banking-1)
        ├── chaos infra v2    hpb-chaos-team-1
        └── experiment        import from a **workshop** org/account hub template (TF_VAR_experiment_*)
    └── project team-2 … same pattern, namespace banking-2
```

**Org (shared):** delegate, optional AWS connector. **No** Connector templates (NG has no that type).  
**Each project (isolated):** K8s connector, Prometheus, env, infra `hpbk8s`, discovery (cluster-scoped collector, Inclusion = that project's namespace only, e.g. team-1 → `banking-1`), chaos, optional experiment import.

`harness-resources/` apply order: remote state (EKS + `banking-N`) → org → projects → delegate Helm on **hpb-eks** → connectors / env / infra → discovery → chaos v2 → experiment import only if both `TF_VAR_experiment_hub_identity` and `TF_VAR_experiment_template_identity` are set (hub in **this** account).

## Folders and state

```text
harness-payment-bank/
├── README.md                 ← this file
├── hpb-manifest/hpb-k8s/     ← app YAML (do not edit for this flow)
├── infrastructure/           ← (2) EKS + banking-N
└── harness-resources/        ← (3) org workshop + team-N  (main.tf + variables.tf)
```

| Terraform root | S3 state key | Destroys |
| --- | --- | --- |
| `infrastructure/` | `hpb-eks/terraform.tfstate` | Cluster and apps |
| `harness-resources/` | `hpb-harness/terraform.tfstate` | Org `workshop` only — **not** EKS |

## EKS (`infrastructure/`)

Deploys EKS `hpb-eks`, namespaces `banking-1` … `banking-N`, vendored `hpb-manifest/hpb-k8s` (do not edit), Prometheus per namespace, Postgres DBs, and frontend gateway URL. Terraform files: `main.tf` + `variables.tf`. Typical create **25–40 minutes**; destroy **20–30 minutes**.

Optional `TF_VAR_*` (empty export can blank a default — only set what you mean):

| Variable | Default |
| --- | --- |
| `aws_region` | `us-east-1` |
| `cluster_name` | `hpb-eks` |
| `namespace_prefix` | `banking` |
| `namespace_count` | `4` |
| `deploy_apps` | `true` |
| `manifests_path` | `../hpb-manifest/hpb-k8s` |

Pipeline stage 1: provisioner `hpb_infrastructure`, folder `./harness-payment-bank/infrastructure`. Native Apply. **Destroy this root only if that Apply fails** — not if stage 2 fails. A failed create can leave IAM role `hpb-eks-ebs-csi` / cluster name in use; clean leftovers before the next create.

**Local create** (no auto-rollback on day-2 updates — a failed update must not destroy a cluster you want to keep):

```bash
cd harness-payment-bank/infrastructure
terraform init
terraform apply
terraform output service_endpoints
terraform output kubeconfig_command
```

**Local destroy:**

```bash
cd harness-payment-bank/infrastructure
terraform destroy -auto-approve
# expect empty: terraform state list
# expect ResourceNotFoundException:
aws eks describe-cluster --name hpb-eks --region us-east-1
```

Destroy drains Kubernetes LoadBalancers before VPC delete (`k8s-elb-*` SGs are not Terraform resources). Do not delete the VPC first; EKS ENIs stay in-use until the cluster is gone.

**Leftover cleanup** (after destroy, or when state is empty but AWS still has objects):

```bash
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER=hpb-eks
export ROLE="${CLUSTER}-ebs-csi"

aws eks describe-cluster --name "$CLUSTER" --query 'cluster.{name:name,status:status,vpc:resourcesVpcConfig.vpcId}' --output table || true
aws iam get-role --role-name "$ROLE" --query 'Role.RoleName' --output text || true

if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[]' --output text \
  | tr '\t' '\n' | while read -r ng; do
      [ -n "$ng" ] || continue
      aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng"
      aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$ng"
    done
  aws eks delete-cluster --name "$CLUSTER"
  aws eks wait cluster-deleted --name "$CLUSTER"
fi

VPCS=$(aws ec2 describe-vpcs --filters Name=tag:Project,Values=hpb --query 'Vpcs[].VpcId' --output text)
for VPC in $VPCS; do
  aws elb describe-load-balancers --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" --output text \
    | tr '\t' '\n' | while read -r name; do
        [ -n "$name" ] || continue
        aws elb delete-load-balancer --load-balancer-name "$name"
      done
  aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" --output text \
    | tr '\t' '\n' | while read -r arn; do
        [ -n "$arn" ] || continue
        aws elbv2 delete-load-balancer --load-balancer-arn "$arn"
      done
done

if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text \
    | tr '\t' '\n' | while read -r arn; do
        [ -n "$arn" ] || continue
        aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$arn"
      done
  aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text \
    | tr '\t' '\n' | while read -r name; do
        [ -n "$name" ] || continue
        aws iam delete-role-policy --role-name "$ROLE" --policy-name "$name"
      done
  aws iam delete-role --role-name "$ROLE"
fi

for VPC in $VPCS; do
  aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC" \
    --query "NatGateways[?State!='deleted'].NatGatewayId" --output text \
    | tr '\t' '\n' | while read -r nat; do
        [ -n "$nat" ] || continue
        aws ec2 delete-nat-gateway --nat-gateway-id "$nat"
      done
  sleep 30
  aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$VPC" \
    --query 'InternetGateways[].InternetGatewayId' --output text \
    | tr '\t' '\n' | while read -r igw; do
        [ -n "$igw" ] || continue
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC"
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
      done
  aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" --query 'Subnets[].SubnetId' --output text \
    | tr '\t' '\n' | while read -r sn; do
        [ -n "$sn" ] || continue
        aws ec2 delete-subnet --subnet-id "$sn"
      done
  aws ec2 delete-vpc --vpc-id "$VPC" || true
done
```

If an ENI is still `in-use` with description `Amazon EKS hpb-eks`, wait for `aws eks wait cluster-deleted` — do not detach those ENIs by hand.

After apply: `aws eks update-kubeconfig --region us-east-1 --name hpb-eks`, then `kubectl get pods -n banking-1`. Prometheus manifests hardcode namespace `banking`; Terraform rewrites live ConfigMaps to `banking-N`. `transaction-service` probes are softened after apply so cold starts do not CrashLoop.

## End-to-end deploy

### A. Once per Harness account

1. Create PAT (Token) in the **workshop** account (`cTU1l…`). Store as a Harness secret the pipeline can read.
2. Pipeline variable `harness_account_id` = `cTU1lRSWS2SSRV9phKvuOA`.
3. Delegate `hpb-demo-delegate` can talk to AWS. TerraformApply needs `terraform`, `aws`, `kubectl` on the plugin/delegate. Helm CLI is optional (the Helm **provider** does not use it).
4. Git: branch `automate_workshop` for stage 2 (`harness-resources/`); `infrastructure/` may still be on `main`.

### B. Pipeline `harness-payment-bank-demo`

```text
Plan EKS → Approve (once) → Apply EKS
                          → Apply Harness resources
```

- Stage 1 working dir: `harness-payment-bank/infrastructure`  
  Provisioner id: `hpb_infrastructure`. Destroy **only** if EKS Apply fails.
- Stage 2 working dir: `harness-payment-bank/harness-resources`  
  Provisioner id: **`hpb_harness_resources`**. Inline apply. Branch `automate_workshop`.  
  Failure: **Mark as Failure**. Retry **this stage only**. Do not destroy EKS. Do not add TerraformDestroy on this stage.

**Environment variables on TerraformApply_2** (not on `ensure_helm`):

| Name | Value |
| --- | --- |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` | Secrets |
| `AWS_DEFAULT_REGION` | `us-east-1` |
| `HARNESS_PLATFORM_API_KEY` | PAT issued in **`cTU1l…`** |
| `HARNESS_ACCOUNT_ID` | `cTU1lRSWS2SSRV9phKvuOA` |
| `TF_VAR_account_id` | `cTU1lRSWS2SSRV9phKvuOA` |

**Do not set** `TF_VAR_create_organization=false` now that org `workshop` is in Terraform state. That plans a destroy of the org. Default is `true`. Org has `lifecycle.prevent_destroy`.

**`ensure_helm`:** install Helm if missing. No `cd`, no `terraform import`, no git clone. Native TerraformApply fetches the repo.

**Skip Refresh Command:** leave **off** for normal retries. Turn **on** only if refresh 404s on a resource gone in Harness but still in state. `TF_CLI_ARGS_apply=-refresh=false` does **not** skip Harness’s separate `terraform refresh` command.

Do not put both Terraform roots in one step. Do not add another Plan → Approve loop for stage 2.

### C. After both stages are green

PnC (`orgs/PnC/projects/team1/settings/discovery/banking1`) is the **layout reference only**. It already has a populated agent. Workshop discovery is a different org/project/agent:

`https://app.harness.io/ng/account/cTU1lRSWS2SSRV9phKvuOA/module/chaos/orgs/workshop/projects/team_1/settings/discovery`

Open agent **`hpb-discovery-team-1`**. PnC’s is **`DA-banking-1`**; its Namespace dropdown lists **`banking-1`**. Do not name the workshop agent `banking-1`. Delete leftover agents named `banking-1`, `hpb_k8s`, and `custom-discovery-agent`.

1. UI: **Organizations → workshop → project team-1** (id `team_1`), not PnC / `team1`.
2. Confirm env `hpb`, infra **`hpbk8s`**, discovery **`hpb-discovery-team-1`**, chaos `hpb-chaos-team-1`.
3. Settings must match PnC except env/infra ids. Every one of these five, not four:

| Field | PnC `DA-banking-1` | Workshop must be |
|---|---|---|
| Namespace (install) | `harness-delegate-ng` | `harness-delegate-ng` |
| Custom cron | `0/15 * * * *` | `0/15 * * * *` (step < 15 is rejected) |
| Namespace filter | Inclusion `banking-1` | Inclusion `banking-N` |
| Detect network trace connectivity | **off** | **off** |
| Use this Service Account | `chaos-delegate` | `chaos-delegate` |

   Network trace is the one that is easy to miss: turning it on adds *For a duration of (in mins)* plus a required node selector, and the form refuses to submit with **"Please add node selector"**, so the collector never schedules. The docs say to disable it whenever you scope with Inclusion. First collection can take ~15 minutes (not 10). Then the Namespace dropdown lists `banking-1`.
4. On **hpb-eks** (not the pipeline delegate’s cluster):

```bash
aws eks update-kubeconfig --region us-east-1 --name hpb-eks
kubectl get pods -n harness-delegate-ng
kubectl get sa chaos-delegate -n harness-delegate-ng
kubectl get pods,svc,deploy -n banking-1
```

5. Turn Skip Refresh Command **off** if you had turned it on. Do not leave `TF_VAR_create_organization=false` on the step.
6. If `TF_VAR_experiment_template_identity` and `TF_VAR_experiment_hub_identity` were set, each `team-N` has the imported experiment. Those identities must belong to a hub **in this account**, not PnC.
7. Run the experiment in `team-1`. Faults stay in `banking-1`.

### D. Tear down

- Workshop only: `terraform destroy` in `harness-resources/` **after** removing `prevent_destroy` on the org if you truly want `workshop` gone. Cluster stays.
- Everything: destroy harness-resources first, then `infrastructure/`.
- Never destroy EKS because stage 2 failed.

### Local apply (workshop root)

```bash
export HARNESS_PLATFORM_API_KEY='pat.cTU1lRSWS2SSRV9phKvuOA.…'
export TF_VAR_account_id=cTU1lRSWS2SSRV9phKvuOA
export AWS_DEFAULT_REGION=us-east-1

cd harness-payment-bank/harness-resources
terraform init
terraform apply
```

Do not `terraform destroy` this root to “fix” a failed apply.

## Precautions (read before every apply)

1. **Retry apply, never destroy harness-resources on a failed workshop apply.** Objects already in S3 state stay; missing ones are created. Destroying org `workshop` after a timeout throws away work and orphans cluster objects.
2. **Two identifier alphabets.** Harness CD identifiers: `[A-Za-z_][0-9A-Za-z_]*` (underscores, **no hyphens**). Helm release names: DNS-1123 (hyphens, **no underscores**). Anything used as **both** (chaos event-watcher stem = CD infra id) must be **lowercase letters and digits only** → `hpbk8s`.
3. **PAT account = `TF_VAR_account_id` = org workshop account (`cTU1l…`).** Pipeline project can live in `l7B…`. Wrong pairing → 401. If org is already in **state**, keep `create_organization=true`.
4. **Shell steps do not clone the repo.** `cd harness-payment-bank/harness-resources` in `ensure_helm` always fails.
5. **`kubectl` in `local-exec` is not the Helm provider.** Bare `kubectl` on the pipeline delegate talks to **that** cluster (shared `harness-delegate-ng`). Always `aws eks update-kubeconfig --name hpb-eks` first.
6. **Discovery `infra_identifier` is immutable.** You cannot PATCH an agent from `hpb_k8s` to `hpbk8s`.
7. **`jsonencode(null)` is the bash word `null`.** Chaos CONNECTOR/DDCR usually returns no install command — `apply_chaos_install_command` defaults **false**.
8. **Push the branch TerraformApply fetches** (`automate_workshop`). Stale Git looks like old resource addresses in the log.
9. **SSO / AWS session tokens expire.** Stage 1 approval is 10 minutes. Refresh AWS secrets before a late stage 2.
10. **Connector type templates do not exist** in NG. Do not add `harness_platform_template` with `type: Connector`.

## Incident log (errors we already hit)

Fix in Git, push `automate_workshop`, retry **stage 2**. Do not destroy EKS.

| Symptom | Cause | What we do now |
| --- | --- | --- |
| `401 Unauthorized` on org/project | PAT from another account, first-gen `HARNESS_API_KEY`, or `TF_VAR_account_id` ≠ PAT account | Account `cTU1l…` + next-gen PAT + matching `TF_VAR_account_id` |
| `403` create organization | No **create organization** permission, or org already exists | Permissions, or `create_organization=false` **only if org is not in TF state** |
| `Invalid template type Connector` | NG template API | Connectors via `harness_platform_connector_*` only |
| `cd … harness-resources: No such file` | Shell step has no git checkout | `ensure_helm` = Helm only |
| Helm `cannot re-use a name that is still in use` | Release on cluster, not in state | `upgrade_install = true`, `take_ownership = true` |
| Delegate ready dumps `qa-private-upgrader`, `vanilla-delegate` CrashLoop | `kubectl` used the **pipeline** cluster | `aws eks update-kubeconfig` for `hpb-eks`; label-scoped pod list |
| Helm `context deadline exceeded` | `wait = true` on a slow delegate | `wait = false`; poller; timeout 1200s |
| `gocron: .Every() interval must be greater than 0` | Discovery cron expression omitted | Default `0/15 * * * *` |
| `collection window should be between 1 <-> 10` | Provider docs use 15; this API max is 10 | `discovery_collection_window_in_min = 10`, and it is only sent when network trace is on |
| `event-watcher-hpb_k8s` invalid Helm name | Underscore in CD infra id | Identifier **`hpbk8s`** |
| `infrastructureDefinition.identifier` regex fail | Hyphen in CD infra id (`hpb-k8s`) | Same **`hpbk8s`** |
| `cannot update immutable fields: … infra_identifier` | Discovery already bound to `hpb_k8s` | Resource address `workshop`; do not PATCH |
| Refresh `Not Found` on discovery | Agent gone in Harness but still in state. Harness runs **`terraform refresh`** separately | `removed { destroy = false }` on old address; skip refresh **only for that apply**. `TF_CLI_ARGS_apply` does not skip it |
| Plan destroys `harness_platform_organization.this[0]` | `TF_VAR_create_organization=false` while org is in state | Keep `create_organization=true`. `prevent_destroy` on the org |
| `bash: null: command not found` in `install_chaos` | `install_command` is null; script retried 8×20s | Default `apply_chaos_install_command=false`; treat `null` as skip |
| Discovery Connected, Last Discovery N/A, empty dropdown | Cron `*/10` (UI min 15), install ns `hpb-sd-1`, empty SA | Install ns `harness-delegate-ng`, SA `chaos-delegate`, cron `0/15 * * * *`, Inclusion `banking-N`. Keep env `hpb` / infra `hpbk8s`. Re-apply stage 2 |
| Still N/A after matching install ns / SA / cron | `enable_node_agent = true` → form wants a node selector and blocks on **"Please add node selector"**. PnC has network trace off | `discovery_enable_network_trace = false` (default). Node selector and collection window go `null` with it |
| `Update Discovery Agent` button instead of `Edit` | Agent record exists but the collector was never installed with a valid config | Fix the config, bump `terraform_data.discovery_cluster_scope`, re-apply so the agent is replaced |
| Stage 2 fully green, but Discovery History has **zero** runs and `harness-delegate-ng` has **no CronJob** | **The delegate is not Ready.** Installing a collector is a delegate task, so a crash-looping delegate means it never runs — no amount of agent config fixes this | `kubectl get pods -n harness-delegate-ng`. `0/1 Running` with a high restart count is the real fault. Fix the delegate first, then re-apply |
| Delegate logs `401 ACCOUNT_DOES_NOT_EXIST` on every call, delegate never registers | Two causes, both proven against the UI install command: (1) `manager_endpoint` was `https://app.harness.io` but this account is on the **gratis** cluster and needs **`https://app.harness.io/gratis`**; (2) `decode_delegate_token = true` base64-decoded a token the chart wants in **base64** form | Set `manager_endpoint = "https://app.harness.io/gratis"` and `decode_delegate_token = false`. Note the UI is still served from `app.harness.io` and `harness_gateway_endpoint` still has no `/gratis` — the NG gateway routes by account id, the delegate manager API does not, which is why Terraform applies stayed green over a dead delegate |
| Unsure what the delegate should be given | Read the copy command on `/account/<acct>/module/chaos/settings/delegates/list`. `managerEndpoint`, `delegateToken` and `delegateDockerImage` there are ground truth — mirror them in `variables.tf` rather than inferring from the UI hostname |
| Delegate gate goes green over a dead delegate | `null_resource.delegate_ready` fell back to `grep -qiE 'Running\|1/1'`, which matches the literal `0/1   Running` of a crash-looping pod | Trust only `kubectl wait --for=condition=Ready`. The fallback is removed, and the failure path now dumps restart counts, probe failures and `--previous` logs |
| Stage 2 fully green, but Discovery History has **zero** runs | A green apply only proves the agent *record* was written. The collector install is a separate delegate task | Read the `discovery_installation` output in the apply log. `delegate_task_status` is the real answer; empty `installation_details` means no install task was ever created |
| `installation_type` seems to have no effect | The provider never sends it — `resource_agent.go` only does `d.Set("installation_type", …)` from the API response. Its vocabulary is `Connector` / `Helm` / `Manifest` / `Yaml`, so our `CONNECTOR` never matched anything | Do not set it on the resource. `var.discovery_installation_type` is retained as unused so an existing `TF_VAR_` on the step does not warn |

## If something already existed (rename)

Older applies used Harness project id `banking_1`. This layout uses `team_1`. Terraform will want to **replace** those projects. For a clean workshop:

```bash
cd harness-payment-bank/harness-resources
# remove prevent_destroy on the org first if destroy must delete workshop
terraform destroy   # Harness only
terraform apply
```

Do not destroy `infrastructure/` just to rename teams.

## What this automation changed (commit notes)

- Flattened `harness-resources/` (no modules). No Connector templates.
- `create_organization` + org `prevent_destroy`. Data lookup only when org is **not** in state.
- Delegate Helm: `wait=false`, `upgrade_install`, `take_ownership`, upgrader off; ready poll uses **hpb-eks** kubeconfig.
- Infra identifier **`hpbk8s`**; validation rejects `_` and `-`.
- Discovery: name `hpb-discovery-team-N`; install `harness-delegate-ng` + SA `chaos-delegate`; cron `0/15`; Inclusion `banking-N`; network trace off.
- Chaos v2 on `hpbk8s`; `apply_chaos_install_command` default false.
- Optional experiment import from a **this-account** hub only.

| Area | Layout |
| --- | --- |
| Terraform | Project `team_N`; project K8s connector `hpb_eks`; Prometheus per project; infra id **`hpbk8s`** |
| Pipeline | Unique provisioner id; PAT + account `cTU1l…`; stage 2 after EKS |
| Talk track | **team-1** in Harness, **banking-1** in kubectl |
| Experiments | Hub templates in org `workshop` (or account); import when `TF_VAR_experiment_*` is set |
| AWS | Namespaces stay `banking-N` |
