# Ops answers

<!-- TEMPLATE. The task: "max 1.5 pages total" for the four questions, so about 150-200 words each. Write in your own
     words; the "points to cover" are prompts, not an answer key, and any claim you make you must be able to defend
     live. Delete these comments when done. -->

## 1. EKS 1.33 to 1.35 with zero downtime: order and top 3 risks

<!-- Points to cover:
     - why it has to be two upgrades (one minor version at a time) and that the control plane cannot be downgraded
     - what you check BEFORE touching anything: removed/deprecated APIs in use, add-on compatibility with the target
       version, PodDisruptionBudgets and spare capacity for draining, a rollback story
     - the order: control plane, then the add-ons (vpc-cni, coredns, kube-proxy, EBS/EFS CSI) to versions compatible
       with the new control plane, then the nodes (managed node group rolling update or Karpenter drift) and why nodes
       must not be newer than the control plane
     - how you keep traffic safe during node rolls (PDBs, surge, readiness) and how you validate between steps
     Your top 3 risks, each with how you would reduce it. -->

YOUR TEXT.

## 2. Spot reclaims at 3 AM page on-call for non-issues: an alerting strategy

<!-- Points to cover:
     - alert on user-visible symptoms (SLO, error rate, latency, not-ready replicas) rather than on node count
     - tell "node going away on purpose" from "node failed": spot interruption notices / node termination handling,
       a `for:` duration long enough to ride out a normal replacement, inhibition rules
     - what still pages: capacity below a threshold, workloads not ready, nodes NotReady for much longer than a
       normal replacement, a nodepool that cannot get capacity
     - how you keep real node failures from being hidden by the suppression, and how you would test it -->

YOUR TEXT.

## 3. LCP of 5 s on a marketing site behind Cloudflare: is HTML caching working?

<!-- Points to cover, as ordered steps:
     - headers first: `curl -I` and the Cloudflare cache status (HIT / MISS / DYNAMIC / BYPASS), Cache-Control,
       Set-Cookie, Vary, Age
     - what Cloudflare caches by default (static file types, not HTML) and what a rule for HTML needs
     - what makes a response uncacheable at the origin (no-store/private, cookies, Vary) and how to confirm it
     - the origin side (TTFB with and without the cache), then the LCP element itself (image size/format/priority)
     - how you would confirm the fix (repeat the same requests, real-user data / WebPageTest) -->

YOUR TEXT.

## 4. Application secrets on EKS: two approaches, and my pick for a startup with several production clusters

<!-- Points to cover:
     - two approaches compared on: where the source of truth lives, how a pod gets the value, rotation, auditing,
       access control (IAM roles for service accounts / Pod Identity), GitOps friendliness, operational cost
       (for example External Secrets Operator with AWS Secrets Manager, Secrets Store CSI Driver, Sealed Secrets/SOPS)
     - your pick for THIS situation (small team, several clusters) and the reason, including what you give up -->

YOUR TEXT.
