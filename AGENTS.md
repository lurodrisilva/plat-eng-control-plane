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
   kubectl explain flexibleserver --api-version=dbforpostgresql.azure.m.upbound.io/v1beta1
   ```

## The private-network constraint

Every Azure resource composed here is reachable **only over the private network**. This is a
platform guarantee, not a per-app option — an app cannot opt out, because the XR has no field
for it:

- **PostgreSQL Flexible Server** — VNet-injected into the delegated subnet, `publicNetworkAccessEnabled: false`.
- **Redis** — `publicNetworkAccessEnabled: false` plus a `PrivateEndpoint` and a zone group.

If you add a resource, it gets a private path before it gets merged.

## Connection details: compose the Secret, do not project it

**Crossplane v2 removed composite-resource connection details.** An XR has no
`writeConnectionSecretToRef`, and a Composition's `connectionDetails:` blocks are collected and
then **silently dropped** — no error, no secret. Do not add them; they look right and do nothing.

The underlying requirement is unchanged. A bare `FlexibleServer` exposes its host **only** as
`status.atProvider.fqdn` and never writes it to a secret — upjet publishes only fields it deems
sensitive, and an fqdn is a plain computed attribute. A pod cannot read a CR's status. So the
Composition still has to deliver a Secret; it just has to *compose* one:

```yaml
- name: connection-secret
  base: {apiVersion: v1, kind: Secret, type: Opaque}
  patches:
  - type: FromCompositeFieldPath
    fromFieldPath: status.fqdn          # put there by a ToCompositeFieldPath patch on the MR
    toFieldPath: stringData.host
    policy: {fromFieldPath: Required}   # no secret until the host is real
```

The contract each block delivers into the app's namespace:

| Block | Secret | Keys | Written by |
|-------|--------|------|------------|
| Postgres | `<name>-postgres-conn` | `host`, `port`, `username`, `dbname` | composed |
| Postgres | `<name>-admin-password` | `password` | the provider (`autoGeneratePassword: true`) |
| Redis | `<name>-redis-conn` | `host`, `port` | composed |
| Redis | `<name>-auth` | `attribute.*` incl. the access key | the provider |

**Never mint or template a credential here.** Postgres uses `autoGeneratePassword: true` so the
provider generates one into the secret we name; Redis's access key is sensitive, so upjet
publishes it. This chart handles neither.

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
make all      # lint + render + test + verify
```

Each check has a blind spot, and knowing which is the point:

| Target | Sees | Blind to |
|--------|------|----------|
| `lint` | chart syntax | everything semantic |
| `render` | what a Composition produces, patches applied | CRD schemas — it never contacts a cluster |
| `test` | the top-level objects, against live CRDs | anything inside a Composition's `base` |
| `verify` | the **rendered** resources, against live CRDs | resources that need a second pass |

**`make verify` is the one that catches a bad base.** `render` will happily emit a field that
does not exist, and `test` treats a Composition's `base` as opaque — the two blockers found in
review (a nonexistent `administratorPasswordSecretRef.namespace`, a nonexistent
`FlexibleServerDatabase` `forProvider.name`) passed *both* cleanly. Only dry-running the
rendered output caught them.

Do not reach for `kubeconform` here. It carries no schemas for Crossplane types, so it skips
every resource and reports success while validating nothing — worse than no check, because it
looks like one.

## Traps worth knowing

- **Provider RBAC is the classic silent failure.** A missing subnet-join or
  `Private DNS Zone Contributor` on the SP shows up as an XR stuck non-`Ready` with the real
  error buried in the *managed resource's* conditions, not the XR's:
  `kubectl describe flexibleserver <name> -n <ns>`.
- **Private-DNS propagation lags provisioning.** Gate consumers on XR `Ready` *plus* a DNS/TCP
  check; Ready does not mean resolvable.
- **Provisioning is slow and recreates are destructive** — Flexible Server ~5-10 min, Redis
  ~15-20 min. Several `forProvider` fields are immutable; changing one replaces the server.
