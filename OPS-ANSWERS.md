# Ops answers

## 1. EKS 1.33 to 1.35 with zero downtime: order and top 3 risks

**Before:** scan for removed APIs (kubent or Pluto), check the add-ons (vpc-cni, CoreDNS, kube-proxy, EBS/EFS CSI) against AWS's compatibility list, confirm PDBs and spare capacity, and rehearse on staging, because a control plane cannot be downgraded.

**Order:** control plane one minor at a time (1.33 to 1.34 to 1.35), then the add-ons one by one, then the nodes last (a kubelet must not be newer than the API server). Add new nodes first and drain the old ones once the new ones are Ready; check a `curl` loop through the Ingress after each step.

**Top 3 risks:**

1. Removed APIs or incompatible add-ons: scan, compatibility list, staging.
2. Stateful pods killed on drain (EBS is zone-bound): PDB, graceful shutdown, spare capacity in the same zone, snapshot first.
3. A bad add-on breaks DNS or networking: one at a time, test DNS and the Ingress between steps, revert the version if needed.

## 2. Spot reclaims at 3 AM page on-call for non-issues: an alerting strategy

**Principle:** page on user impact, not on node count: replicas below desired for longer than a normal replacement, high p95 or error rate, pods Pending because no capacity can be obtained. `KubeNodeUnreachable` becomes a ticket or chat notification, and pages only if a node stays NotReady well beyond a normal replacement.

**Cut the noise:** use a `for:` longer than a normal spot replacement, and drain the node on purpose from the 2-minute spot notice (Karpenter or the Node Termination Handler), so pods move before it dies.

**Not hiding real failures:** mute node alerts only for spot nodes that are cordoned or draining, with an expiry, never for on-demand nodes; the symptom alerts are never muted. Test two cases: drain a spot node (expect no page) and stop a node abruptly (expect a page after the `for:` time).

## 3. LCP of 5 s on a marketing site behind Cloudflare: is HTML caching working?

1. **Headers:** `curl -I https://site/` and read `cf-cache-status` (HIT, MISS, EXPIRED, DYNAMIC, BYPASS), `Cache-Control`, `Set-Cookie`, `Vary` and `Age`. DYNAMIC means Cloudflare does not treat the HTML as cacheable.
2. **Rules:** by default Cloudflare caches static file types, not HTML. HTML needs a Cache Rule (eligible for cache, with an edge TTL) and a bypass for logged-in or cart cookies.
3. **Origin:** `Cache-Control: no-store` or `private`, cookies on every response, or a broad `Vary` can make HTML uncacheable. Confirm with `curl -I` straight to the origin, then fix or override them. Compare TTFB (`curl -w '%{time_starttransfer}'`) on a HIT and on a MISS.
4. **The LCP element:** find it with PageSpeed Insights or DevTools. It is often a hero image: check size and format (WebP or AVIF), `fetchpriority=high`, no lazy-loading, preload, and render-blocking CSS.
5. **Confirm:** repeat the same requests (HIT, `Age` growing, lower TTFB) and compare field data (CrUX or RUM) or WebPageTest before and after.

## 4. Application secrets on EKS: two approaches, and my pick for a startup with several production clusters

**A. External Secrets Operator + AWS Secrets Manager.** The source of truth is Secrets Manager; the operator syncs values into Kubernetes Secrets using an IAM role for the service account (or Pod Identity). Rotation and CloudTrail auditing come from AWS, and Git only holds `ExternalSecret` references, so it fits GitOps.

**B. Sealed Secrets (or SOPS).** Secrets are encrypted in Git and decrypted in the cluster. There is no cloud dependency and it is cheap, but every cluster has its own key, rotation is manual, and there is no central audit or access control.

**Pick: A.** With several production clusters, one central store with IAM-scoped access, rotation and an audit trail beats a key per cluster. What I give up: a dependency on AWS and one more controller to run, and the values still land in etcd as Secrets, so I turn on KMS envelope encryption.
