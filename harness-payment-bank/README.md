# Harness Payment Bank — end-to-end workshop

This is the internal map of the whole workshop. Read this first. The two Terraform folders are only *how* to build pieces; this file is *what exists and how it connects*.

PnC (`orgs/PnC` in the chaos module) is the **shape** we copy: one org, one delegate, templates at org, then **one isolated project per team**. We do not copy PnC’s names or its account blindly.

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

Kubernetes names and Harness names are **different on purpose**:

| Kubernetes (AWS) | Harness (org `workshop`) |
| --- | --- |
| namespace `banking-1` | project **`team-1`** (id `team_1`) |
| namespace `banking-2` | project **`team-2`** (id `team_2`) |
| namespace `banking-N` | project **`team-N`** (id `team_N`) |

Same number. Attendee “team 1” breaks only `banking-1`.

## PAT — which account?

The token in secret `HARNESS_PLATFORM_API_KEY` / `Naren_Harness_Platform_API` must be created in **the same Harness account that should own org `workshop`**.

That account id is:

- the `accountId=` in the browser URL when you will open **Organizations → workshop**, and
- pipeline variable `harness_account_id` / `TF_VAR_account_id`.

| If workshop should sit… | Create the PAT in… |
| --- | --- |
| Next to **PnC** (URL account `cTU1lRSWS2SSRV9phKvuOA`) | **My Profile → API Keys → Token** while logged into **that** account |
| In the same account as pipeline `PROD` / `CHAOS` | That account (the id in *that* browser URL) |

Rules:

1. PAT account = `TF_VAR_account_id` = URL account. Mismatch → **401 Unauthorized**.
2. You need the **Token** string (`pat.<accountId>.…`), not the API key *name*.
3. The pipeline can live in `PROD`/`CHAOS` of that same account. The pipeline’s home project is not org `workshop`.
4. A PnC PAT cannot create `workshop` in a different account. Copying PnC’s *layout* does not mean copying PnC’s *account* unless you explicitly want workshop there.

Account id is not a secret. The PAT is.

## What gets created (target layout)

```text
Harness account  <── PAT belongs here
└── org workshop
    ├── delegate          hpb-workshop-delegate   (pod on hpb-eks)
    ├── templates         connector recipes (k8s / aws / prometheus)
    ├── aws connector     org-level, optional (not required for chaos)
    └── project team-1    (attendee 1)     namespace banking-1
        ├── k8s connector     hpb_eks          → delegate → cluster
        ├── environment       hpb
        ├── infra             hpb_k8s          → namespace banking-1
        ├── prometheus        hpb-prometheus-team-1  → prometheus.banking-1
        ├── discovery         hpb-discovery-team-1
        ├── chaos infra v2    hpb-chaos-team-1
        └── experiment        import from template (UI, not Terraform yet)
    └── project team-2 … same pattern, namespace banking-2
```

**Org (shared):** delegate, templates.  
**Each project (isolated):** k8s connector, env, infra, prometheus, discovery, chaos, experiments.

## Folders and state

```text
harness-payment-bank/
├── README.md                 ← this file
├── hpb-manifest/hpb-k8s/     ← app YAML (do not edit for this flow)
├── infrastructure/           ← (2) EKS + banking-N
└── harness-resources/        ← (3) org workshop + team-N
```

| Terraform root | S3 state key | Destroys |
| --- | --- | --- |
| `infrastructure/` | `hpb-eks/terraform.tfstate` | Cluster and apps |
| `harness-resources/` | `hpb-harness/terraform.tfstate` | Org `workshop` only — **not** EKS |

## End-to-end deploy

### A. Once per Harness account

1. Create PAT (Token) in the **workshop** account. Store as a Harness secret the pipeline can read.
2. Pipeline variable `harness_account_id` = that account id.
3. Delegate `hpb-demo-delegate` can talk to AWS (keys or, later, IRSA). It must have `terraform`, `aws`, `kubectl`, **helm**.
4. Git: branch that contains `harness-resources/` (e.g. `automate_workshop`) for stage 2; `infrastructure/` may still be on `main`.

### B. Pipeline `harness-payment-bank-demo`

```text
Plan EKS → Approve (once) → Apply EKS
                          → Apply Harness resources
```

- Stage 1 working dir: `harness-payment-bank/infrastructure`  
  Provisioner id: `hpb_infrastructure`. Destroy **only** if EKS Apply fails.
- Stage 2 working dir: `harness-payment-bank/harness-resources`  
  Provisioner id: **`hpb_harness_resources`** (never reuse the EKS id).  
  Inline apply (no stored plan). Env: `AWS_*`, `HARNESS_PLATFORM_API_KEY`, `TF_VAR_account_id`.  
  Failure: **Mark as Failure**. Retry **this stage only**.

Do not put both Terraform roots in one step. Do not add another Plan → Approve loop for stage 2.

### C. After both stages are green

1. UI: **Account → Organizations → workshop → project team-1**.
2. Confirm env `hpb`, infra `hpb_k8s`, discovery and chaos for `banking-1`.
3. Cluster: `kubectl get pods -n harness-delegate-ng` and `-n banking-1`.
4. **Import experiment from template** into `team-1` (and each team). Terraform does not do this yet.
5. Run the experiment in `team-1`. Faults stay in `banking-1`.

### D. Tear down

- Workshop only: `cd harness-resources && terraform destroy` (or a dedicated destroy pipeline). Cluster stays.
- Everything: destroy harness-resources first, then `infrastructure/`.

## If something already existed (rename)

Older applies used Harness project id `banking_1`. This layout uses `team_1`. Terraform will want to **replace** those projects. For a clean workshop:

```bash
cd harness-payment-bank/harness-resources
terraform destroy   # Harness only
terraform apply
```

Do not destroy `infrastructure/` just to rename teams.

## Changes this layout needs (checklist)

| Area | Change |
| --- | --- |
| `harness-resources` Terraform | Project `team_N`; K8s + Prometheus **in the project**; infra `connectorRef` is project `hpb_eks` (not `org.hpb_eks`) |
| Pipeline | Unique provisioner id; PAT + account id of **workshop** account; Helm on delegate; stage 2 after EKS |
| Docs / talk | Say **team-1** for Harness, **banking-1** for kubectl |
| Experiments | Still UI: import from org/account chaos templates into each `team-N` |
| PAT | Workshop account only (see above) |
| AWS | No change: namespaces stay `banking-N` |

Operator detail for Terraform (imports, pipeline YAML, failure table): [`harness-resources/README.md`](harness-resources/README.md).  
EKS apply/destroy: [`infrastructure/README.md`](infrastructure/README.md).
