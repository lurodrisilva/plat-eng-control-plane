# plat-eng-control-plane

The **Crossplane control plane** for the Azure platform: every Crossplane API object the
platform offers lives here and is versioned together.

## What this repo owns

| Layer | Contents |
|-------|----------|
| Packages | `Provider` (Upbound `provider-family-azure` + services), `Function` (composition functions) |
| Credentials | `ClusterProviderConfig` — binds providers to the Azure service principal |
| Environment | `EnvironmentConfig` — per-cluster network facts (subnet / private-DNS-zone IDs) |
| API | `CompositeResourceDefinition` (XRD) — the platform's offered kinds |
| Implementation | `Composition` — how each kind becomes real Azure resources |

Building-block Helm charts (`plat-eng-building-block-sql-database`,
`plat-eng-building-block-cache`) *consume* these APIs by rendering an XR into the
application's namespace. They do not define them.

## What this repo does not own

- The Azure substrate (VNet, subnets, private-DNS zones, AKS, the service principal and its
  Kubernetes `Secret`) — that is `plat-eng-aks-foundation` (Terraform).
- Crossplane core itself — installed by Terraform via an ArgoCD `Application`.
- The ArgoCD `Application` that syncs *this* repo — that is `plat-eng-baseline-addons`.

## Layout

```text
chart/
  Chart.yaml
  values.yaml              # defaults + toggles
  values-aks-test.yaml     # per-environment network facts (generated — see below)
  templates/
    00-providers.yaml
    01-functions.yaml
    10-clusterproviderconfig.yaml
    11-environmentconfig.yaml
    20-xrd-postgresinstance.yaml
    21-xrd-redisinstance.yaml
    30-composition-postgresinstance.yaml
    31-composition-redisinstance.yaml
```

Templates are numbered to match their ArgoCD sync wave: packages install before the
credentials that configure them, which install before the XRDs, which install before the
Compositions that reference them.

## Per-environment values are generated, not written

`values-<env>.yaml` carries resource IDs that Terraform owns. Regenerate rather than edit:

```sh
make env-config ENV=aks-test
```

It reads `terraform output -json` from `plat-eng-aks-foundation` and rewrites the file. If a
subnet or zone is ever recreated, re-run it — a stale ID surfaces as a Crossplane claim that
never reaches `Ready`.

## Validate

```sh
make lint      # helm lint — offline
make render    # crossplane render — offline, runs the functions locally via Docker
make test      # server-side dry-run against the live CRDs — needs cluster access, creates nothing
```

`make render` is the fastest way to see whether a Composition does what you think before
anything touches Azure. It prints the actual managed resources, with patches applied — so a
missing `delegatedSubnetId` or a `publicNetworkAccessEnabled: true` is visible in seconds.

Note that Redis renders its `PrivateEndpoint` only on the **second** pass: the endpoint needs
the cache's Azure resource id, which does not exist until the cache does. Rendering an XR with
`status.cacheId` populated shows the completed graph. That is the intended behaviour, not a bug.

## Requirements

Crossplane **v2**. This repo uses `apiextensions.crossplane.io/v2` XRDs with `scope: Namespaced`
and composes **namespaced** managed resources (the `*.m.upbound.io` API groups). Claims are not
used — in Crossplane v2 a namespaced XR *is* the thing a claim used to stand in for.
