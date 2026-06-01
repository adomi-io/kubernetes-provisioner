# Adomi - Kubernetes Provisioner

This sets up a fresh Kubernetes cluster with the tools most projects need: HTTPS certificates, ingress, databases, message
queues, single sign-on, and somewhere to run jobs. You point it at an empty cluster, set your domain, and run one command.

It installs **Argo CD** - a GitOps engine that keeps the cluster matching what's in this repo - and hands the rest over to it.
From there, Argo CD brings everything else up on its own.

Here's what you get:

- **cert-manager** - free TLS certificates from Let's Encrypt, renewed for you
- **Traefik** - ingress: routes traffic to your apps and handles HTTPS
- **CloudNativePG** - Postgres databases on demand
- **JuiceFS** - a shared POSIX filesystem, backed by object storage
- **RabbitMQ Operator** - message queues
- **Authentik** - single sign-on, one login across your apps
- **Argo Workflows** - runs jobs and pipelines
- **OpenBao + External Secrets** - secrets live in OpenBao (installed for you), never in this repo

> [!NOTE]
> Most of these are *operators*. An operator installs into the cluster and then manages something for you - you ask for a database
> or a queue, and it creates one and looks after it. This repo installs the operators; your own projects create the instances (a
> Postgres `Cluster`, a `RabbitmqCluster`, and so on).

## How it works

```
helmfile apply
  ├─ argo-cd            the GitOps engine
  └─ argocd-root        one root app that points Argo CD at this repo
        └─ Argo CD brings up everything else, in order:
             cert-manager · external-secrets
             cluster-issuers · traefik · cloudnative-pg · rabbitmq · juicefs
             openbao            (then you unseal it - see Secrets)
             cluster-secrets
             authentik · argo-workflows
```

Helmfile only installs Argo CD and that one root app. Everything else is just a file in [`argocd/templates/`](argocd/templates/)
that tells Argo CD what to install. Argo CD reads them from git and keeps the cluster in sync.

The order matters - Authentik can't get a certificate until cert-manager is running, for example - so each piece is tagged with a
[sync wave](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/). Argo CD finishes one wave before starting the next.
This is the official Argo CD
[app-of-apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/).

# Getting started

> [!WARNING]
> These commands run against whatever cluster `kubectl` is pointed at. Make sure you're on the right one first.
>
> ```bash
> kubectl config use-context your-cluster
> kubectl get nodes
> ```

Pipe the installer into your shell. It grabs `kubectl`, `helm`, and `helmfile` if you don't have them, downloads this repo, and
applies it. Give it your domain and Let's Encrypt email - either as variables, or let it ask you.

```bash
curl -fsSL https://raw.githubusercontent.com/adomi-io/kubernetes-provisioner/main/install.sh \
  | DOMAIN=example.com ACME_EMAIL=you@example.com sh -s -- apply
```

Running it in a terminal without those? It'll just ask:

```bash
curl -fsSL https://raw.githubusercontent.com/adomi-io/kubernetes-provisioner/main/install.sh | sh -s -- apply
#   Domain (e.g. example.com): ...
#   Email for Let's Encrypt: ...
```

Want to look before you touch the cluster? Run it with no arguments to just download everything.

```bash
curl -fsSL https://raw.githubusercontent.com/adomi-io/kubernetes-provisioner/main/install.sh | sh
```

### From a clone

```bash
git clone https://github.com/adomi-io/kubernetes-provisioner.git
cd kubernetes-provisioner

# First run on a fresh cluster: --skip-diff-on-install lets Argo CD install its
# CRDs before the root app is diffed. (The curl installer adds this for you.)
helmfile apply --skip-diff-on-install
```

### With Docker

The image already has `kubectl`, `helm`, and `helmfile` in it. Mount your kubeconfig and run it.

```bash
docker run --rm -it \
  -v "$HOME/.kube/config:/root/.kube/config:ro" \
  ghcr.io/adomi-io/kubernetes-provisioner:latest \
  apply
```

# Layout

```
.env.example                    # copy to .env and fill in - all settings live here
config.yaml.gotmpl              # reads those settings (env vars) into Helmfile
helmfile.yaml.gotmpl            # the bootstrap: installs Argo CD + the root app
values/
  argo-cd.yaml.gotmpl           # Argo CD's own settings (its dashboard at argocd.<domain>)
charts/
  argocd-root/                  # the root app that starts it all
  cluster-issuers/              # the Let's Encrypt issuers
  cluster-secrets/              # the OpenBao connection + which secrets to pull
  rabbitmq-cluster-operator/    # the RabbitMQ operator
argocd/                         # everything Argo CD installs
  values.yaml                   # versions, OpenBao settings, and what's passed down from config
  templates/                    # one file per component (cert-manager, traefik, authentik, ...)
.github/workflows/deploy.yml    # bootstrap from CI using a GitHub Environment
install.sh                      # the bootstrap installer
Dockerfile                      # the same, as a container image
```

# Configuration

Everything is set with environment variables, so you can run this without editing a single file - from a `.env`, from your shell,
or from GitHub. `config.yaml.gotmpl` just reads those variables, with placeholder defaults for anything you don't set.

```bash
cp .env.example .env     # then fill it in
```

| Variable | What it is | Default |
|---|---|---|
| `DOMAIN` | your domain; apps land at `<app>.<domain>` | `example.com` |
| `ACME_EMAIL` | Let's Encrypt registers your certs under this | `you@example.com` |
| `GIT_REPO_URL` | the repo Argo CD reads the platform from | this repo |
| `GIT_TARGET_REVISION` | the branch/tag Argo CD tracks | `main` |
| `BAO_ADDR` | OpenBao address (defaults to the in-cluster one this installs) | `http://openbao.openbao.svc.cluster.local:8200` |
| `BAO_KV_MOUNT` | the KV v2 mount holding your secrets | `secret` |
| `BAO_KUBERNETES_AUTH_MOUNT` | OpenBao's Kubernetes auth mount path | `kubernetes` |
| `BAO_KUBERNETES_AUTH_ROLE` | the OpenBao role the operator logs in as | `external-secrets` |
| `BAO_AUTHENTIK_SECRET_PATH` | path to Authentik's secrets in OpenBao | `authentik` |
| `BAO_ARGO_WORKFLOWS_SECRET_PATH` | path to Argo Workflows' SSO creds | `argo-workflows` |

The installer loads `.env` for you. Running `helmfile` directly instead? Export them first:

```bash
export $(grep -v '^#' .env | xargs)
helmfile apply
```

> [!IMPORTANT]
> Argo CD reads from git, not from your laptop. `GIT_REPO_URL` / `GIT_TARGET_REVISION` must point at a repo the **cluster** can
> reach, and changes need to be pushed before they take effect. If you customize anything under `argocd/` or `charts/`, point these
> at your own fork.

## Deploying from GitHub Actions

There's a [deploy workflow](.github/workflows/deploy.yml) that runs the bootstrap from CI against a GitHub
[Environment](https://docs.github.com/actions/deployment/targeting-different-environments). For each environment, set the variables
above as **Variables** (`DOMAIN`, `ACME_EMAIL`, `BAO_ADDR`, ...) and add the target cluster's kubeconfig as a base64-encoded
`KUBECONFIG` **secret**. Then run the workflow and pick the environment.

```bash
# the value to paste into the KUBECONFIG secret
base64 -w0 < ~/.kube/config
```

## Secrets

Secrets can't live in git, so this repo runs **[OpenBao](https://openbao.org)** in the cluster (the open-source fork of HashiCorp
Vault) and the [External Secrets Operator](https://external-secrets.io/) copies values out of it into Kubernetes `Secret`s when a
component needs them. Nothing secret is ever committed - only a pointer to where it lives in OpenBao.

The flow is:

1. **`openbao`** runs the secrets store (standalone, on a PVC, so secrets persist).
2. **`external-secrets`** installs the operator that talks to it.
3. **`cluster-secrets`** declares where each secret lives, and the operator writes it into a normal `Secret` (e.g. `authentik-secrets`).
4. The component reads that `Secret` - Authentik gets its signing key and database password from it.

The operator logs in with its own cluster identity, so no token is stored anywhere. OpenBao is API-compatible with Vault, so
External Secrets talks to it through its `vault` provider.

### Unseal and set up OpenBao (one time)

OpenBao comes up **sealed** on first boot, and the bootstrap waits there until you initialise and unseal it. Open a shell to the
pod:

```bash
kubectl -n openbao exec -it openbao-0 -- sh
```

```bash
# 1. Initialise. This prints unseal keys and a root token - SAVE THEM SOMEWHERE
#    SAFE. They are shown once and are the only way back in.
bao operator init

# 2. Unseal (repeat with the number of keys it asks for)
bao operator unseal

# 3. Log in with the root token, then turn on a KV store, Kubernetes auth, and a
#    read-only policy for the operator.
bao login
bao secrets enable -path=secret kv-v2
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"
bao policy write external-secrets - <<'EOF'
path "secret/data/*"      { capabilities = ["read"] }
path "secret/metadata/*"  { capabilities = ["read"] }
EOF
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets ttl=1h

# 4. Store the secrets the platform needs
bao kv put secret/authentik \
  secret_key="$(openssl rand -base64 60 | tr -d '\n')" \
  postgres-password="$(openssl rand -base64 24 | tr -d '\n')"
```

Once it's unsealed and these are in place, External Secrets syncs them and the remaining apps finish coming up. The KV mount, auth
path, role, and secret paths are the `BAO_*` variables - keep them matching.

> [!NOTE]
> With manual unseal, OpenBao **re-seals whenever its pod restarts** - you'd unseal it again. For hands-off restarts, set up
> auto-unseal below.

### Auto-unseal with a cloud KMS

To have OpenBao unseal itself (and stay unsealed across restarts), point it at a cloud KMS: set `BAO_SEAL_CONFIG` to a
[`seal` stanza](https://openbao.org/docs/configuration/seal/) for your provider, and grant OpenBao access to the key with a
service-account annotation.

```bash
# AWS KMS (key access via IRSA - the annotation is the IAM role ARN)
BAO_SEAL_CONFIG='seal "awskms" { region = "us-east-1" kms_key_id = "<key-id-or-arn>" }'
BAO_SA_ANNOTATION_KEY=eks.amazonaws.com/role-arn
BAO_SA_ANNOTATION_VALUE=arn:aws:iam::<account>:role/openbao-unseal

# GCP Cloud KMS (key access via Workload Identity)
BAO_SEAL_CONFIG='seal "gcpckms" { project = "<proj>" region = "global" key_ring = "<ring>" crypto_key = "<key>" }'
BAO_SA_ANNOTATION_KEY=iam.gke.io/gcp-service-account
BAO_SA_ANNOTATION_VALUE=openbao-unseal@<proj>.iam.gserviceaccount.com
```

Azure Key Vault and Transit seals work the same way - see the [seal docs](https://openbao.org/docs/configuration/seal/).

With a seal set, `bao operator init` hands you **recovery keys** instead (keep them just as safe), OpenBao unseals itself, and it
stays unsealed across restarts - so skip the `bao operator unseal` step above. The rest of the setup (auth, policy, secrets) is
unchanged.

### Adding a secret for another component

Add an `ExternalSecret` to `charts/cluster-secrets/templates/`, put the value in OpenBao, and point the component at the `Secret`
that comes out. Use the Authentik files as a template.

### Argo Workflows single sign-on

The Argo Workflows UI logs in through Authentik. Authentik has to know about the app first, so there's a one-time setup in the
Authentik UI:

1. Create an **OAuth2 / OpenID Provider**. Set its redirect URI to `https://argo.<your-domain>/oauth2/callback` and client type to
   *Confidential*. Note the **Client ID** and **Client Secret** it gives you.
2. Create an **Application** for that provider with the slug `argo-workflows` (that slug is the `argo-workflows` in the issuer URL).
3. Decide who gets in: put those people in an Authentik group, and make sure the provider includes the **groups** scope so Argo can
   see it.
4. Store the two credentials in OpenBao, where the `argo-workflows-sso` ExternalSecret picks them up:

```bash
bao kv put secret/argo-workflows \
  client-id="<client id from authentik>" \
  client-secret="<client secret from authentik>"
```

Roles map from those Authentik groups - the Argo Workflows [SSO + RBAC docs](https://argo-workflows.readthedocs.io/en/latest/argo-server-sso/)
show how to make a group admin vs read-only. Until you set that up, everyone who logs in gets the default (read-only) access.

# Usage

```bash
helmfile apply --skip-diff-on-install   # first bootstrap: install Argo CD + the root app
kubectl -n argocd get applications      # watch Argo CD bring everything up
```

`--skip-diff-on-install` is only needed the first time - it stops helmfile diffing the root app before Argo CD's `Application` CRD
exists. After the first run, plain `helmfile apply` works.

Early on, Argo CD's own web address won't have a certificate yet (Traefik and cert-manager are still coming up). Reach it directly
with a port-forward:

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443
# the starting admin password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Traefik asks the cloud for a load balancer with a public IP. Read its address and point your DNS (`*.example.com`) at it.

```bash
kubectl -n traefik get svc traefik
```

> [!TIP]
> After the first run, you don't go back to the command line for changes. Edit the files under `argocd/`, push, and Argo CD picks it
> up. You only re-run `helmfile apply` to change Argo CD itself.

# Adding an app

Drop a new file in `argocd/templates/`. For something off the shelf, add its chart to `argocd/values.yaml` and point at it:

```yaml
# argocd/templates/my-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"   # comes up after the things it depends on
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://charts.example.com
    chart: my-app
    targetRevision: 1.2.3
    helm:
      valuesObject:
        ingress:
          hosts:
            - my-app.{{ .Values.domain }}
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ CreateNamespace=true ]
```

If it lives in this repo instead (like `cluster-issuers` or `rabbitmq-cluster-operator`), point `repoURL` / `targetRevision` at
`{{ .Values.gitRepoURL }}` / `{{ .Values.gitTargetRevision }}` and set `path:` to its folder.

# Continuous integration

On every push and pull request, [CI](.github/workflows/ci.yml) renders all the manifests (`helmfile template` and
`helm template ./argocd`) so a bad chart version or typo fails there instead of on your cluster. On `main` it also builds and
publishes the Docker image to `ghcr.io/adomi-io/kubernetes-provisioner`.

# Requirements

Helm 4 and Helmfile 1. The installer and image pin `helm v4.2.0` and `helmfile 1.5.2` and grab anything you're missing.

# License

See the [LICENSE](LICENSE) file.
