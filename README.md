> [!TIP]
> **Want a cluster up fast?**
>
> Point this at an empty cluster and run one command. It grabs `kubectl`, `helm`, and `helmfile` if you're missing them, downloads this repo, and applies it.
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/adomi-io/kubernetes-provisioner/main/install.sh \
>   | DOMAIN=example.com ACME_EMAIL=you@example.com sh -s -- apply
> ```

# Adomi - Kubernetes Provisioner

This turns an empty Kubernetes cluster into one you can actually build on: HTTPS certificates, ingress, Postgres, object
storage, message queues, single sign-on, and somewhere to run jobs. You point it at a fresh cluster, give it your domain, and run
one command.

`helmfile apply` installs **Argo CD** - a GitOps engine that keeps the cluster matching what's in this repo - and a single root
app. Argo CD brings everything else up from git. You edit files, push, and Argo CD syncs them to the cluster.

> [!NOTE]
> **Related repositories**
>
> - [adomi-io/adomi-platform-controller](https://github.com/adomi-io/adomi-platform-controller) - the operator that reconciles `SSOApplication` resources into Authentik + OpenBao. Deployed at wave 5; lives in its own repo.

# What you get

This repo installs the operators and shared infrastructure; your projects create the instances they manage (a Postgres `Cluster`, a
`RabbitmqCluster`, and so on).

- 🔒 [**cert-manager**](https://cert-manager.io) - TLS certificates from Let's Encrypt, renewed automatically
- 🚦 [**Traefik**](https://traefik.io) - ingress: routes traffic to your apps and terminates HTTPS
- 🐘 [**CloudNativePG**](https://cloudnative-pg.io) - Postgres on demand, with backups to object storage
- 🐇 [**RabbitMQ Operator**](https://www.rabbitmq.com/kubernetes/operator/operator-overview) - message queues
- 🗄️ [**SeaweedFS**](https://github.com/seaweedfs/seaweedfs) - an in-cluster S3 object store
- 📁 [**JuiceFS**](https://juicefs.com) - a shared POSIX filesystem, backed by object storage
- 🔑 [**Authentik**](https://goauthentik.io) - single sign-on, one login across your apps
- ⚙️ [**Argo Workflows**](https://argo-workflows.readthedocs.io) - runs jobs and pipelines, logged in through Authentik
- 📡 [**Argo Events**](https://argoproj.github.io/argo-events/) - trigger workflows from webhooks, queues, and schedules
- 🔐 [**OpenBao**](https://openbao.org) + [**External Secrets**](https://external-secrets.io) - secrets live in OpenBao and are delivered into the cluster as `Secret`s
- 🤖 [**adomi-platform-controller**](https://github.com/adomi-io/adomi-platform-controller) - turns an `SSOApplication` resource into an Authentik app + credentials

# How it works

`helmfile apply` installs exactly two things:

- **Argo CD** - the GitOps engine.
- **`argocd-root`** - one root `Application` that points Argo CD at the [`argocd/`](argocd/) folder in this repo.

That's the whole bootstrap. Everything else - cert-manager, Traefik, OpenBao, Authentik, all of it - is just a file under
[`argocd/templates/`](argocd/templates/), one `Application` per component. Argo CD reads them from git and keeps the cluster in
sync. This is the standard Argo CD
[app-of-apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/): the root app's only job is
to declare the other apps.

Each app is tagged with a [sync wave](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/) so it comes up in order;
Argo CD finishes one wave before starting the next:

| Wave | Comes up |
|---|---|
| 0 | cert-manager, external-secrets |
| 1 | Traefik, cluster-issuers, CloudNativePG, JuiceFS, RabbitMQ operator |
| 2 | OpenBao |
| 3 | openbao-bootstrap, cluster-secrets, authentik-db, argo-events |
| 4 | SeaweedFS, Authentik, Argo Workflows |
| 5 | adomi-platform-controller, app-databases (per-app Postgres + glue Secrets) |
| 6 | platform-resources (the `SSOApplication`s) |
| 7 | the [platform stack](#platform-stack) - Odoo, Grafana/Prometheus/Alertmanager, Loki, Tempo, Uptime Kuma, Forgejo, Harbor, Outline, Windmill, Superset, Vaultwarden, Open WebUI, LiteLLM |

You won't find these in `helmfile.yaml.gotmpl` - it only knows about Argo CD and the root app. Each one is a file in
[`argocd/templates/`](argocd/templates/), and the versions and settings they share live in [`argocd/values.yaml`](argocd/values.yaml).

# Platform stack

The platform stack is a set of user-facing apps (wave 7), each at `<app>.<domain>`, wired into the platform: Postgres from
CloudNativePG, object storage on SeaweedFS, single sign-on through Authentik, and HTTPS via Traefik + cert-manager. Stateful
apps get their own Postgres `Cluster` (with backups), created with the namespaces and glue Secrets by the
[`app-databases`](charts/app-databases) app in wave 5.

| App | URL | What it is | Database | SSO |
|---|---|---|---|---|
| **Odoo** | `odoo.` | ERP / business apps | CNPG | manual (needs the `auth_oidc` addon in the image) |
| **Grafana** | `grafana.` | dashboards | - | ✅ Authentik (forward-auth, header login) |
| **Prometheus / Alertmanager** | _(in-cluster)_ | metrics + alerting | - | no ingress (no built-in auth) - port-forward |
| **Traefik dashboard** | `traefik.` | ingress / router dashboard | - | ✅ Authentik (forward-auth) |
| **Loki** | _(datasource)_ | logs (S3-backed) | - | - |
| **Tempo** | _(datasource)_ | traces (S3-backed) | - | - |
| **Uptime Kuma** | `status.` | uptime / status page | - | ✅ Authentik (forward-auth) |
| **Forgejo** | `git.` | git forge | CNPG | ✅ Authentik (forward-auth, header login) |
| **Harbor** | `harbor.` | container registry (S3-backed) | CNPG | ✅ Authentik (forward-auth + OIDC) |
| **Outline** | `docs.` | wiki / knowledge base (S3-backed) | CNPG | ✅ Authentik (forward-auth + OIDC) |
| **Windmill** | `windmill.` | workflow / script automation | CNPG | ✅ Authentik (forward-auth; OIDC manual) |
| **Superset** | `superset.` | BI / dashboards | CNPG | ✅ Authentik (forward-auth + OIDC) |
| **Vaultwarden** | `vault.` | password manager | CNPG | ✅ Authentik (forward-auth; master password) |
| **Open WebUI** | `chat.` | chat UI for LLMs | CNPG | ✅ Authentik (forward-auth, header login) |
| **LiteLLM** | `llm.` | LLM gateway / proxy | CNPG | ✅ Authentik (forward-auth + OIDC; Enterprise beyond 5 users) |

Every app sits behind Authentik **forward-auth**: a domain-level `proxy` `SSOApplication` and a per-namespace
`ak-forward-auth` Traefik Middleware ([`charts/platform-resources`](charts/platform-resources/templates/forward-auth.yaml))
check each request against Authentik's embedded outpost, so you sign in once at Authentik. Behind the gate, Forgejo,
Grafana and Open WebUI auto-login from the `X-authentik-*` headers (no second screen); the others keep their own OIDC
login, which is seamless because the Authentik session already exists; Vaultwarden still asks for its master password.
Self-registration is off everywhere. The [`adomi-platform-controller`](#single-sign-on) reconciles each `SSOApplication`
(in [`charts/platform-resources`](charts/platform-resources)) into the Authentik apps, groups, and (for the OIDC apps) the
`<app>-sso` credentials.

`openbao-bootstrap` generates these app secrets into OpenBao (its `appSecrets` list) and External Secrets delivers them:
Grafana's admin password, Superset's secret key, Odoo's master password, Harbor's admin password, LiteLLM's master key,
and Outline's `SECRET_KEY`/`UTILS_SECRET`.

## SSO configured by hand

These apps can't take their OIDC config from Helm and aren't auto-configured. Their Authentik app and credentials are
provisioned; finish the OIDC client in each app:

- **Windmill** - add the provider under *Instance Settings → SSO/OAuth* using `windmill-sso` (a fully generic OIDC
  provider may need Windmill Enterprise).
- **Odoo** - Odoo Community needs the OCA `auth_oidc` addon baked into the image, then configured in Odoo's settings.

# Getting started

> [!WARNING]
> These commands run against whatever cluster `kubectl` is pointed at. Check you're on the right one first.
>
> ```bash
> kubectl config use-context your-cluster
> kubectl get nodes
> ```

Pipe the installer into your shell. It grabs `kubectl`, `helm`, `helmfile`, and the `helm-diff` plugin if you don't already have
them, downloads this repo, and applies it. Give it your domain and Let's Encrypt email - as variables, or let it prompt you.

```bash
curl -fsSL https://raw.githubusercontent.com/adomi-io/kubernetes-provisioner/main/install.sh \
  | DOMAIN=example.com ACME_EMAIL=you@example.com sh -s -- apply
```

Without those variables, the installer prompts for them:

```bash
curl -fsSL https://raw.githubusercontent.com/adomi-io/kubernetes-provisioner/main/install.sh | sh -s -- apply
#   Domain (e.g. example.com): ...
#   Email for Let's Encrypt: ...
#   Authentik admin email (Enter to skip admin setup): ...
#   Authentik admin password (login user is "akadmin"): ...
```

Those last two are optional - press Enter to skip them - but if you fill them in you can log straight into Authentik as `akadmin`
without its web setup step. The password is hashed locally and only the hash ever reaches the cluster (see
[Logging in as the admin](#logging-in-as-the-admin)).

Run it with no command to download everything without applying it.

```bash
curl -fsSL https://raw.githubusercontent.com/adomi-io/kubernetes-provisioner/main/install.sh | sh
```

### From a clone

```bash
git clone https://github.com/adomi-io/kubernetes-provisioner.git
cd kubernetes-provisioner

# First run on a fresh cluster: --skip-diff-on-install lets Argo CD install its
# Application CRD before the root app is diffed. (The curl installer adds this.)
DOMAIN=example.com ACME_EMAIL=you@example.com helmfile apply --skip-diff-on-install
```

### With Docker

The image already has `kubectl`, `helm`, and `helmfile` baked in. Mount your kubeconfig and run it.

```bash
docker run --rm -it \
  -v "$HOME/.kube/config:/root/.kube/config:ro" \
  -e DOMAIN=example.com \
  -e ACME_EMAIL=you@example.com \
  ghcr.io/adomi-io/kubernetes-provisioner:latest \
  apply
```

### Running on k3s

k3s ships its own Traefik, which collides with the one this repo installs - both claim the `traefik` `IngressClass` and try to bind
ports 80/443, so one ends up stuck `Pending`. Disable k3s's bundled Traefik.

On a fresh node, disable it at install:

```bash
curl -fsSL https://get.k3s.io | sh -s - --disable=traefik
```

On a node that's already running, make it persistent and restart:

```yaml
# /etc/rancher/k3s/config.yaml
disable:
  - traefik
```

```bash
sudo systemctl restart k3s
```

Then `helmfile apply` as usual - our Traefik takes the `traefik` `IngressClass` and k3s's ServiceLB gives it the node's IP. Point
your DNS there.

**Raise the node's inotify limits.** A single node running every controller at once exhausts the default inotify limits, and pods
crash with `too many open files` / `failed to create fsnotify watcher`. Bump them on the node:

```ini
# /etc/sysctl.d/99-inotify.conf
fs.inotify.max_user_instances=512
fs.inotify.max_user_watches=1048576
```

```bash
sudo sysctl --system   # apply now; persists across reboots
```

If a pod already crash-looped on this, delete it after raising the limits and Argo CD recreates it.

# Configuration

Everything is set with environment variables, so you can run this without editing a single file - from a `.env`, from your shell,
or from GitHub. [`config.yaml.gotmpl`](config.yaml.gotmpl) just reads those variables, with placeholder defaults for anything you
don't set.

```bash
cp .env.example .env     # then fill it in
```

| Variable | What it is | Default |
|---|---|---|
| `DOMAIN` | your domain; apps land at `<app>.<domain>` | `example.com` |
| `ACME_EMAIL` | Let's Encrypt registers your certs under this | `you@example.com` |
| `AUTHENTIK_ADMIN_EMAIL` | email for the initial Authentik admin (`akadmin`); prompted if unset, blank to skip | _(empty)_ |
| `AUTHENTIK_ADMIN_PASSWORD` | password for that admin; hashed locally, read by Authentik on first boot only; never stored in git/OpenBao | _(empty)_ |
| `GIT_REPO_URL` | the repo Argo CD reads the platform from | this repo |
| `GIT_TARGET_REVISION` | the branch/tag Argo CD tracks | `main` |
| `INGRESS_CLASS` | the `IngressClass` apps use | `traefik` |
| `CLUSTER_ISSUER` | the cert-manager `ClusterIssuer` apps use | `letsencrypt-prod` |
| `S3_ENDPOINT` | object store endpoint (defaults to the in-cluster SeaweedFS) | in-cluster SeaweedFS |
| `S3_BUCKET` | the bucket name | `platform` |
| `BAO_UNSEAL_MODE` | `kubernetes` (self-managed, no cloud) or `kms` (auto-unseal via cloud KMS) | `kubernetes` |
| `BAO_SEAL_CONFIG` | HCL `seal` stanza for `kms` mode (see [Secrets](#secrets)) | _(empty)_ |
| `BAO_ADDR` | OpenBao address (defaults to the in-cluster one this installs) | `http://openbao.openbao.svc.cluster.local:8200` |
| `BAO_KV_MOUNT` | the KV v2 mount holding your secrets | `secret` |
| `BAO_KUBERNETES_AUTH_MOUNT` | OpenBao's Kubernetes auth mount path | `kubernetes` |
| `BAO_KUBERNETES_AUTH_ROLE` | the OpenBao role External Secrets logs in as | `external-secrets` |
| `BAO_AUTHENTIK_SECRET_PATH` | path to Authentik's secrets in OpenBao | `authentik` |
| `BAO_ARGO_WORKFLOWS_SECRET_PATH` | path to Argo Workflows' SSO creds in OpenBao | `argo-workflows` |

The installer loads `.env`. To run `helmfile` directly, export them first:

```bash
export $(grep -v '^#' .env | xargs)
helmfile apply
```

> [!IMPORTANT]
> Argo CD reads from git, not from your laptop. `GIT_REPO_URL` / `GIT_TARGET_REVISION` must point at a repo the **cluster** can
> reach, and changes have to be pushed before they take effect. If you customize anything under `argocd/` or `charts/`, point these
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

# Secrets

Secrets can't live in git, so this repo runs **[OpenBao](https://openbao.org)** in the cluster (the open-source fork of HashiCorp
Vault) and the [External Secrets Operator](https://external-secrets.io/) copies values out of it into Kubernetes `Secret`s when a
component needs them. Nothing secret is ever committed - only a pointer to where it lives in OpenBao.

The flow is:

- **`openbao`** runs the secrets store (standalone, file storage on a PVC, so secrets persist across restarts).
- **`openbao-bootstrap`** initialises, unseals, and configures OpenBao, then seeds the platform's secrets (below).
- **`external-secrets`** installs the operator that talks to OpenBao.
- **`cluster-secrets`** declares the `ClusterSecretStore` (the connection to OpenBao) and the `ExternalSecret`s, and the operator
  writes each one into a normal `Secret` (e.g. `authentik-secrets`, `seaweedfs-s3-config`).
- The component reads that `Secret`. Authentik gets its signing key and bootstrap token from `authentik-secrets`; SeaweedFS gets
  its S3 keys from `seaweedfs-s3-config`.

External Secrets logs in with its own cluster identity (Kubernetes auth), so no token is stored anywhere. OpenBao is
API-compatible with Vault, so it talks to it through the `vault` provider.

## Bootstrap

The **`openbao-bootstrap`** reconciler configures OpenBao after `helmfile apply`:

- runs `operator init`, stores the unseal/recovery keys + root token in the `openbao-keys` Secret, and (in `kubernetes` mode) keeps
  OpenBao unsealed, including after restarts;
- enables the KV v2 store and Kubernetes auth, and creates a read-only policy + role for **External Secrets**;
- creates the read/write policy + role the **adomi-platform-controller** logs in as (read on the Authentik path, read/write on the
  per-app credential paths);
- seeds Authentik's `secret_key` and an API `bootstrap-token` at `secret/authentik`, and the object store's `access-key` /
  `secret-key` at `secret/s3` - each generated randomly, **only if it isn't already there**;
- when per-customer GitOps is on (`tenants.enabled`), mints the **Forgejo service-account token**: it logs in to Forgejo with the
  local admin (random password seeded at `secret/forgejo-admin`, also handed to Forgejo's admin-init by cluster-secrets), ensures the
  tenant org, mints a scoped API token, and stores `{username, token}` at `secret/forgejo-scm` - the credential Argo CD (SCM
  generator + repo creds) and the platform API use to read/write tenant repos. This token is a *real* Forgejo token (it can't be a
  random secret), so it's minted via the API rather than generated; kept on its own path, separate from `secret/forgejo` (the SSO
  OAuth client creds the controller owns). Forgejo comes up after this reconciler, so it simply retries until Forgejo is ready.

It's idempotent: it never re-initialises an initialised OpenBao and never overwrites a secret that already exists. (Authentik's
database password isn't in here - CloudNativePG generates and manages that.)

## Unsealing: pick a mode

OpenBao encrypts everything at rest and boots **sealed** - it needs an unseal key to start serving. `BAO_UNSEAL_MODE` chooses where
that key lives:

- **`kubernetes`** (default) - no cloud KMS needed. The unseal keys are kept in the `openbao-keys` Secret and the reconciler
  unseals OpenBao, including after restarts.

  > [!WARNING]
  > In `kubernetes` mode the unseal keys live in the `openbao-keys` Secret, so OpenBao's at-rest encryption is only as strong as
  > RBAC on that Secret. Lock down access to the `openbao` namespace.

- **`kms`** - OpenBao auto-unseals from a cloud KMS. Set `BAO_UNSEAL_MODE=kms` plus `BAO_SEAL_CONFIG` (and a service-account
  annotation) for your provider:

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

## Recovery / break-glass

The unseal (or recovery) keys and the root token are saved in the **`openbao-keys`** Secret in the `openbao` namespace. Copy them
somewhere safe and restrict who can read that Secret:

```bash
kubectl -n openbao get secret openbao-keys -o jsonpath='{.data.root-token}' | base64 -d
```

For manual admin, log in with that token from the pod:

```bash
RT=$(kubectl -n openbao get secret openbao-keys -o jsonpath='{.data.root-token}' | base64 -d)
kubectl -n openbao exec -it openbao-0 -- bao login "$RT"
```

## Adding a secret for another component

Add an `ExternalSecret` to `charts/cluster-secrets/templates/`, put the value in OpenBao, and point the component at the `Secret`
that comes out. Use [`authentik-externalsecret.yaml`](charts/cluster-secrets/templates/authentik-externalsecret.yaml) as a template.

# Object storage

CloudNativePG backups, JuiceFS volumes, and anything else that wants a bucket need somewhere to put bytes. This repo
installs **SeaweedFS** and runs its S3 gateway in-cluster. The access/secret keys are generated into OpenBao at `secret/s3`
(by `openbao-bootstrap`), turned into the `seaweedfs-s3-config` Secret by External Secrets, and SeaweedFS authenticates with
them.

`S3_ENDPOINT` / `S3_BUCKET` point at an external bucket (DigitalOcean Spaces, AWS S3, ...) instead; put its keys in OpenBao
at `secret/s3`. Everything that reads from `secret/s3`, including the Authentik database backups, uses that endpoint.

# Single sign-on

Authentik is the identity provider - one login across your apps, at `auth.<domain>`. An app that logs in through it (OIDC) needs an
Authentik **provider** + **application**, plus a client ID/secret the app reads. The **`adomi-platform-controller`** creates that
from a Kubernetes resource instead of the Authentik UI. It's an operator that lives in
[`adomi-io/adomi-platform-controller`](https://github.com/adomi-io/adomi-platform-controller), runs in the `adomi-system` namespace,
and watches one CRD:

- **`SSOApplication`** (`identity.adomi.io/v1alpha1`) - an app that needs SSO.

For each `SSOApplication` it:

- generates a `client-id` / `client-secret` pair at `secret/<app>` in OpenBao, **once** - existing values are never overwritten;
- creates (or updates to match) an Authentik OAuth2 provider + Application with those exact credentials, looked up by name/slug so
  re-runs never duplicate;
- ensures any Authentik `groups` you listed exist (membership you manage in Authentik);
- and, if you ask for a `targetSecret`, writes an `ExternalSecret` that delivers the credentials into the app's namespace as a
  normal `Secret`.

**OpenBao is the source of truth** - Authentik is made to match it. On delete the controller removes the Authentik app and provider
but leaves the OpenBao credentials in place, so recreating the resource reuses the same client ID/secret.

It stores no static token. It logs in to OpenBao with its **own ServiceAccount** (OpenBao Kubernetes auth); `openbao-bootstrap`
creates the role and policy. It calls the Authentik API with a bootstrap token that `openbao-bootstrap` generates into
`secret/authentik` (key `bootstrap-token`); Authentik reads it at **first boot** as `AUTHENTIK_BOOTSTRAP_TOKEN` to mint an `akadmin`
API token. That env is read on first boot only, so on a cluster where Authentik already exists, create a token for `akadmin` in the
UI once and store it:

```bash
RT=$(kubectl -n openbao get secret openbao-keys -o jsonpath='{.data.root-token}' | base64 -d)
kubectl -n openbao exec -it openbao-0 -- sh -c \
  "bao login $RT >/dev/null && bao kv patch secret/authentik bootstrap-token=<token>"
```

## Logging in as the admin

The admin user is **`akadmin`**. The installer can set its password: it prompts for an admin email + password (or reads
`AUTHENTIK_ADMIN_EMAIL` / `AUTHENTIK_ADMIN_PASSWORD`), **hashes the password locally**, and drops the hash in a one-time
`authentik-bootstrap` Secret that Authentik reads on first boot. The plaintext never touches git, OpenBao, or even an env var on
disk - only the one-way hash reaches the cluster, and it's ignored after the first boot. Leave the prompt blank to skip it.

If you skipped it (or Authentik is already running), set the password directly:

```bash
kubectl -n authentik exec -it deploy/authentik-server -- ak changepassword akadmin
```

Then log in at `https://auth.<domain>/` as `akadmin`. You can delete the one-time secret afterward; it's never read again:

```bash
kubectl -n authentik delete secret authentik-bootstrap
```

## Giving an app single sign-on

Declare an `SSOApplication` in [`charts/platform-resources`](charts/platform-resources). The required field is `redirectUris`; the
rest have defaults (`scopes` defaults to `openid profile email groups`, the OpenBao path defaults to the app slug).

```yaml
apiVersion: identity.adomi.io/v1alpha1
kind: SSOApplication
metadata:
  name: my-app
  namespace: my-app
spec:
  displayName: My App
  protocol: oauth2
  redirectUris:
    - https://my-app.example.com/oauth2/callback
  scopes: [openid, profile, email, groups]
  # Optional: Authentik groups the controller makes sure exist, so you can gate
  # who signs in (add members in Authentik).
  groups:
    - My App Users
  # Optional: publish the credentials into your app's namespace as a Secret.
  credentials:
    targetSecret:
      name: my-app-sso
```

The controller generates the credentials, sets up Authentik, and writes the `my-app-sso` Secret (keys `client-id` /
`client-secret`) into your app's namespace. Point the app at that Secret - no separate `ExternalSecret` needed, the controller
manages it.

Listing `groups` makes the controller ensure those groups exist in Authentik; how an app maps a group to a role is up to the app.
[`charts/platform-resources`](charts/platform-resources) ships `argo-workflows` as a worked example - it maps the
`Argo Workflows Admins` group to admin via the RBAC `extraObjects` in
[`argocd/templates/argo-workflows.yaml`](argocd/templates/argo-workflows.yaml).

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

Traefik gets a `LoadBalancer` service with an external IP. Read it and point your DNS (`*.example.com`) there.

```bash
kubectl -n traefik get svc traefik
```

> [!TIP]
> Edit the files under `argocd/`, push, and Argo CD picks up the change. Re-run `helmfile apply` to change Argo CD itself.

# Adding an app

Drop a new file in `argocd/templates/`. For something off the shelf, add its chart version to `argocd/values.yaml` and point at it:

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
