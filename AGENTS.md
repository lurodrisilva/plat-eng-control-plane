# plat-eng-control-plane — Agent Contract

The Crossplane control plane for the Azure platform. Read this before changing anything here.

## Non-negotiables

1. **Crossplane v2 only.** XRDs are `apiextensions.crossplane.io/v2` with `scope: Namespaced`.
   **Do not add claims or `X`-prefixed composite twins** — v2 dropped claims, and a namespaced
   XR already is what a claim used to stand in for. `scope: LegacyCluster` is the deprecated
   back-compat path; it is not used here.
2. **Compose namespaced managed resources** — the `*.m.upbound.io` API groups. The
   cluster-scoped legacy groups (`*.upbound.io`) cannot be composed by a namespaced XR.
   A `ClusterProviderConfig` in `azure.m.upbound.io` serves them; a `ProviderConfig` in the
   legacy group does not.
3. **`mode: Pipeline` is mandatory.** Crossplane v2 removed `mode: Resources`. Every
   Composition runs through `function-patch-and-transform`, which must be installed as a
   `Function` package first.
4. **Never hand-edit `values-<env>.yaml`.** Run `make env-config ENV=<env>`. Those IDs belong
   to Terraform.
5. **Verify apiVersions against the live CRDs**, not against memory or docs — Upbound bumps
   MR versions per service and they are not uniform across the family:
   ```sh
   kubectl get crds | grep azure.m.upbound.io
   kubectl explain flexibleserver --api-version=dbforpostgresql.azure.m.upbound.io/v1beta2
   ```

## The private-network constraint

Every Azure resource composed here is reachable **only over the private network**. This is a
platform guarantee, not a per-app option — an app cannot opt out, because the XR has no field
for it:

- **PostgreSQL Flexible Server** — VNet-injected into the delegated subnet, `publicNetworkAccessEnabled: false`.
- **Redis** — `publicNetworkAccessEnabled: false` plus a `PrivateEndpoint` and a zone group.

If you add a resource, it gets a private path before it gets merged.

## The projection that must not be dropped

A bare `FlexibleServer` exposes its host **only** as `status.atProvider.fqdn` and never writes
it to a connection secret — upjet only publishes fields it considers sensitive, and an fqdn is
a plain computed attribute. A pod cannot read a CR's status. So the Composition **must** project
it:

```yaml
connectionDetails:
- type: FromFieldPath
  fromFieldPath: status.atProvider.fqdn
  name: host
```

Remove that and every consumer silently loses its hostname. This is *why* Postgres needs a
Composition rather than a bare managed resource. Same reasoning drives the Redis host/port/key
projection.

## Ordering

Templates are numbered to match ArgoCD sync waves, and the order is causal, not cosmetic:
packages (`00`,`01`) must register their CRDs before the `ClusterProviderConfig` (`10`) that
configures them; XRDs (`20`,`21`) must exist before the Compositions (`30`,`31`) that reference
them via `compositeTypeRef`.

CRDs here are large. The ArgoCD `Application` syncing this repo **must** set
`ServerSideApply=true` — Crossplane and provider CRDs exceed the 262144-byte client-side
`last-applied-configuration` annotation limit.

## Validate before you push

```sh
make lint     # helm lint
make test     # kubeconform
make render   # crossplane render — offline, shows the MRs a Composition produces
```

`make render` costs nothing and catches most Composition mistakes. Use it.

## Traps worth knowing

- **Provider RBAC is the classic silent failure.** A missing subnet-join or
  `Private DNS Zone Contributor` on the SP shows up as an XR stuck non-`Ready` with the real
  error buried in the *managed resource's* conditions, not the XR's:
  `kubectl describe flexibleserver <name> -n <ns>`.
- **Private-DNS propagation lags provisioning.** Gate consumers on XR `Ready` *plus* a DNS/TCP
  check; Ready does not mean resolvable.
- **Provisioning is slow and recreates are destructive** — Flexible Server ~5-10 min, Redis
  ~15-20 min. Several `forProvider` fields are immutable; changing one replaces the server.
