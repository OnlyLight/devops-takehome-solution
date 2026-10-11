# Troubleshooting log: Part 3 (`troubleshoot/broken-app.yaml`)

Commands run inside the toolbox (`docker compose exec toolbox bash`), with `alias k='kubectl -n troubleshoot'`.

## 1. `web`: Pending, "Insufficient memory"

**Symptom.** The `web` pod stays `Pending` with no node assigned.

```text
Warning  FailedScheduling  default-scheduler
  0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 Insufficient memory.
```

**Diagnosis.**

```bash
k get pods -o wide                      # web pod: Pending, NODE <none>
k describe pod <web-pod>                # Events: the FailedScheduling message above
k describe deploy web                   # Pod Template > nginx > Limits / Requests: memory 16Gi
kubectl describe node k3d-itv-agent-0   # Allocatable: memory 10182296Ki (every node reports the same)
```

The container asks for `memory: 16Gi` (request and limit). Every node reports `allocatable.memory = 10182296Ki`, about 9.7 GiB: that is the whole Docker VM, shared by all five k3d nodes (they are containers on one VM). No node can ever hold a 16Gi request.

The "1 node(s) had untolerated taint(s)" part is the GPU node; the four nodes that remain were rejected for memory.

**Root cause.** The scheduler places pods using their **requests**, not their limits and not actual usage. A memory request larger than a node's allocatable memory can never be satisfied, however empty the node is.

**Fix** (`web`, container `nginx`):

```diff
-              memory: 16Gi      # requests
+              memory: 64Mi
-              memory: 16Gi      # limits
+              memory: 128Mi
```

64Mi / 128Mi is the same sizing the same manifest already uses for `ai-inference`. A static nginx serving one HTML file needs far less; I did not profile it, the values are a small choice that leaves headroom.

**Verification.** The replacement pod is scheduled instead of staying Pending:

```text
Normal  Scheduled  default-scheduler  Successfully assigned troubleshoot/web-59bcb98fb-jh5lb to k3d-itv-agent-2
```

## 2. `web`: ContainerCreating, ConfigMap not found

**Symptom.** After fix 1 the pod is scheduled but never leaves `ContainerCreating`.

```text
Normal   Scheduled    default-scheduler  Successfully assigned troubleshoot/web-59bcb98fb-jh5lb to k3d-itv-agent-2
Warning  FailedMount  kubelet            MountVolume.SetUp failed for volume "html" : configmap "web-conf" not found
```

**Diagnosis.**

```bash
k describe pod <web-pod>        # Events: FailedMount, volume "html"; Volumes > html > ConfigMap > Name: web-conf
k get configmap                 # kube-root-ca.crt, web-config  (no web-conf)
```

The scheduler is out of the picture (the pod already has a node): the kubelet fails while preparing the container's volumes. The namespace contains a ConfigMap named `web-config`, but the `html` volume refers to `web-conf`.

**Root cause.** A typo in the volume's `configMap.name`.

**Fix** (`web`):

```diff
       volumes:
         - name: html
           configMap:
-            name: web-conf
+            name: web-config
```

**Verification.** `k describe deploy web` now shows `Volumes > html > Name: web-config`, and `k describe pod` of the replacement pod has no `FailedMount` event under `Events`.

## 3. `web`: ImagePullBackOff, the image tag does not exist

**Symptom.** With scheduling and the volume fixed, the pod is on a node but its container never starts.

```text
Normal   Pulling  kubelet  Pulling image "nginx:1.25.99"
Warning  Failed   kubelet  Failed to pull image "nginx:1.25.99": rpc error: code = NotFound desc = failed to pull and unpack image
                           "docker.io/library/nginx:1.25.99": failed to resolve reference "docker.io/library/nginx:1.25.99": ...
Warning  Failed   kubelet  Error: ErrImagePull
Warning  Failed   kubelet  Error: ImagePullBackOff
```

**Diagnosis.**

```bash
k get pods                       # STATUS ImagePullBackOff
k describe pod <web-pod>         # Events: code = NotFound for docker.io/library/nginx:1.25.99
docker manifest inspect nginx:1.25.99   # fails: the tag does not exist
docker manifest inspect nginx:1.30.5    # succeeds
```

`NotFound` (not `unauthorized` or a timeout) means the registry answered and the tag is simply not there: it is not a rate limit, a network problem or a missing pull secret. I then looked for a real tag on the Docker Hub page for the official `nginx` image.

**Root cause.** `nginx:1.25.99` does not exist.

**Fix** (`web`): use a tag that exists. I chose `1.30.5`: `nginx:stable` and `nginx:1.30.5` resolve to the same image digest (`sha256:9bf97bd7...`, checked with `docker buildx imagetools inspect`), so it is the current stable release of the official image. A pinned tag, not `stable` or `latest`, so the manifest stays reproducible.

```diff
-          image: nginx:1.25.99
+          image: nginx:1.30.5
```

**Verification.** The image is pulled and the container is created:

```text
Normal  Pulled   kubelet  Successfully pulled image "nginx:1.30.5" in 13.819s ... Image size: 63638242 bytes.
Normal  Created  kubelet  Container created
```

## 4. `web-svc`: no endpoints, the selector matches no pod

**Symptom.** The Service exists and has a ClusterIP, but nothing is behind it.

```text
$ k describe svc web-svc
Selector:   app=webapp
Endpoints:                       <- empty
```

**Diagnosis.**

```bash
k describe svc web-svc                         # Selector: app=webapp, Endpoints: empty
k get pods --show-labels                       # the web pods carry app=web
k get pods -l app=webapp                       # No resources found in troubleshoot namespace.
k get pods -l app=web                          # the web pods
k describe endpointslices -l kubernetes.io/service-name=web-svc   # no endpoint listed
```

A Service finds its pods only by label selector. Selecting by the Service's own `app=webapp` returns nothing, while `app=web` returns the pods, so the Service has no backends however healthy the pods are.

**Root cause.** The Service selector `app: webapp` does not match the pod label `app: web`.

**Fix** (`web-svc`):

```diff
   selector:
-    app: webapp
+    app: web
```

**Verification.** The EndpointSlice now lists the pods' addresses (`10.42.0.28`, `10.42.0.29`). They show `ready=false`, which is a separate matter (the pods are not passing their probes yet), not a selector problem: before the fix the list was empty, not "not ready".

## 5. `web`: Running but never Ready, restarting: probes target the wrong port

**Symptom.** The image now starts, but the pod is `Running` with `0/1` ready and its restart counter keeps climbing. The Service endpoints exist but are `ready=false`.

```text
Warning  Unhealthy  kubelet  Readiness probe failed: Get "http://10.42.0.29:8080/": dial tcp 10.42.0.29:8080: connect: connection refused
Warning  Unhealthy  kubelet  Liveness probe failed: Get "http://10.42.0.29:8080/": dial tcp 10.42.0.29:8080: connect: connection refused
Normal   Killing    kubelet  Container nginx failed liveness probe, will be restarted
```

**Diagnosis.**

```bash
k get pods                        # 0/1 Running, RESTARTS 2 and rising
k describe pod <web-pod>          # Events: both probes: connect: connection refused on :8080
                                  # same output, containers section: Port: 80/TCP ; Liveness / Readiness: http-get http://:8080/
k describe endpointslices -l kubernetes.io/service-name=web-svc   # addresses present, Conditions > Ready: false
```

The container declares `containerPort: 80`, while both probes call port `8080`. `connection refused` (not a timeout) is informative: the pod is reachable and the kernel answered immediately that nothing listens on that port. A timeout would have pointed at a network policy or a dropped packet instead.

The two probes have different consequences, and both were visible: a failing **readiness** probe only takes the pod out of the Service endpoints (`ready=false`, `0/1`), while a failing **liveness** probe makes the kubelet **kill and restart** the container (`Killing ... will be restarted`, `RESTARTS` climbing).

**Root cause.** `livenessProbe` and `readinessProbe` use `port: 8080`; nginx serves on port 80.

**Fix** (`web`, both probes):

```diff
           livenessProbe:
             httpGet:
               path: /
-              port: 8080
+              port: 80
           readinessProbe:
             httpGet:
               path: /
-              port: 8080
+              port: 80
```

**Verification.** After the apply both replicas are `1/1 Running` with `RESTARTS 0`, neither pod has an `Unhealthy` or `Killing` event, and the endpoints are ready:

```text
$ k get pods                  web-8658c6858f-f4ln5   1/1   Running   0
                              web-8658c6858f-xtsqz   1/1   Running   0
$ k describe svc web-svc      Endpoints: 10.42.0.31:80,10.42.3.25:80
$ k describe endpointslices -l kubernetes.io/service-name=web-svc    Conditions > Ready: true (both addresses)
```

## 6. `ai-inference`: Pending, two faults stacked (nodeSelector key and missing toleration)

**Symptom.** The `ai-inference` pod stays `Pending` and must end up on the GPU node, without touching the node's labels or taint.

```text
Warning  FailedScheduling  default-scheduler
  0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 node(s) didn't match Pod's node affinity/selector.
```

**Diagnosis.** I ruled out resources first (requests 100m / 64Mi, far below any node's capacity), then compared what the pod asks for with what the GPU node actually carries:

```bash
k describe pod <ai-inference-pod>       # Node-Selectors: node-type=gpu ; Tolerations: only the two default not-ready/unreachable ones
kubectl describe node k3d-itv-agent-3   # Labels: acme.io/node-type=gpu ; Taints: nvidia.com/gpu=true:NoSchedule
```

Two independent faults:

1. **nodeSelector key.** The pod selects `node-type: gpu`; the node's label is `acme.io/node-type: gpu`. Label keys match exactly, prefix included, and no node has a bare `node-type` label. The value was right; only the key was wrong.
2. **No toleration.** The node is tainted `nvidia.com/gpu=true:NoSchedule`, and the pod only has the two default tolerations Kubernetes adds to every pod (`not-ready` / `unreachable`, `NoExecute`), which are unrelated to this taint.

Why the message did not give both away: the scheduler reports **one reason per node, the first filter that rejects it**. Before any fix the GPU node was already listed under "untolerated taint", although the selector would not have matched it either, so the message could not reveal fault 1. After fixing only the selector, the message was word for word the same and the pod was still `Pending`; the evidence for that fix is the label comparison above, and the unchanged message shows the GPU node was now rejected only on its taint.

**Root cause.** A wrong label key in `nodeSelector`, and no toleration for the GPU taint. The two fields do different jobs: the toleration only *allows* the pod onto the tainted node (a taint repels pods; a toleration lifts that for one taint), while the `nodeSelector` is what *forces* it onto the GPU node.

**Fix** (`ai-inference`). Workload only; the node's label and taint are not modified (`prepare.sh` owns them):

```diff
       nodeSelector:
-        node-type: gpu
+        acme.io/node-type: gpu
+      tolerations:
+        - key: "nvidia.com/gpu"
+          operator: "Equal"
+          value: "true"
+          effect: "NoSchedule"
```

`operator: Equal` with the taint's exact value is the narrowest toleration that works: it tolerates `nvidia.com/gpu=true:NoSchedule` and nothing else (`Exists` would also tolerate any other value for that key).

**Verification.** The pod is running on the GPU node, and the node was not touched:

```text
$ k get pods -o wide        ai-inference-f765cc8d8-vqmxr   1/1   Running   k3d-itv-agent-3
$ kubectl describe node k3d-itv-agent-3 | grep -E 'Labels|Taints'
Labels:             acme.io/node-type=gpu
Taints:             nvidia.com/gpu=true:NoSchedule
```

`verify.sh` steps [4/7] (ai-inference rolled out) and [5/7] (ai-inference running on the GPU node) pass.

## 7. `web-svc`: targetPort points at a port nothing listens on

**Symptom.** None observed on its own: this fault was hidden behind the others. While the Service had no endpoints (fault 4), the pods were not Ready (fault 5) and the namespace was default-deny (fault 8), nothing could ever reach `targetPort`. I found it by comparing the Service with the pod, not from a failing request.

**Diagnosis.**

```bash
k describe svc web-svc          # Port: 80/TCP   TargetPort: 8080/TCP
k describe pod <web-pod>        # containers section: Port: 80/TCP
```

A Service forwards `port` to the pod's `targetPort`. The pods listen on 80 (declared `containerPort: 80`), and the readiness probe on `:8080` had already shown `connection refused` (fault 5), which proves nothing listens on 8080 inside the container. A Service forwarding to 8080 could not work even with perfect selectors and policies.

**Root cause.** `targetPort: 8080` in `web-svc`; nginx serves on 80.

**Fix** (`web-svc`):

```diff
   ports:
     - protocol: TCP
       port: 80
-      targetPort: 8080
+      targetPort: 80
```

**Verification.** Calling the Service from a pod that is allowed to (see fault 8) returns the page:

```text
$ curl http://10.43.125.199/        # web-svc ClusterIP, port 80   ->   HTTP 200
```

## 8. Namespace default-deny: the smoke test cannot reach `web-svc` (and cannot resolve its name)

**Symptom.** Everything is Running and Ready, yet `verify.sh` fails at step 7 and the smoke job logs:

```text
curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 3 ms: Couldn't connect to server
FAIL: smoke test failed (check NetworkPolicy/DNS/Service path)
```

**Diagnosis.** The only NetworkPolicy is `default-deny`: it selects every pod (`podSelector: {}`) and lists both `Ingress` and `Egress` with no rules, so nothing may enter or leave any pod. Every connection must be allowed at **both ends**, and the smoke job makes two separate connections because it calls a name:

```text
1. resolve the name  smoke-client -> CoreDNS (kube-system), UDP/TCP 53
2. call the service  smoke-client -> web pod (via the ClusterIP, DNAT to the pod), TCP 80
```

That is three flows to allow: egress from `smoke-client` to web, ingress into web from `smoke-client`, and egress from `smoke-client` to CoreDNS. (CoreDNS needs no ingress rule: no policy selects it, so it is not isolated.) I checked the DNS part separately, from a `app=smoke-client` pod that had been Ready for 20 s, with the web-side rules already in place:

```text
curl http://<web-svc ClusterIP>/                              -> HTTP 200
curl http://web-svc.troubleshoot.svc.cluster.local/           -> curl: (6) Could not resolve host
```

**Root cause.** Default-deny with no allow rules for the smoke client's egress, web's ingress, or DNS.

**Fix.** `default-deny` is left exactly as provided (verify.sh checks it, and the rule is to keep it). Two additional policies; policies are additive, so no existing one is touched:

```yaml
# web may receive TCP 80 from the smoke client only
kind: NetworkPolicy
metadata: { name: allow-smoke-client-to-web, namespace: troubleshoot }
spec:
  podSelector: { matchLabels: { app: web } }
  policyTypes: [Ingress]
  ingress:
    - from: [ { podSelector: { matchLabels: { app: smoke-client } } } ]
      ports: [ { protocol: TCP, port: 80 } ]
---
# the smoke client may send TCP 80 to web, and DNS to CoreDNS, nothing else
kind: NetworkPolicy
metadata: { name: allow-smoke-client-send, namespace: troubleshoot }
spec:
  podSelector: { matchLabels: { app: smoke-client } }
  policyTypes: [Egress]
  egress:
    - to: [ { podSelector: { matchLabels: { app: web } } } ]
      ports: [ { protocol: TCP, port: 80 } ]
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector:       { matchLabels: { k8s-app: kube-dns } }
      ports: [ { protocol: TCP, port: 53 }, { protocol: UDP, port: 53 } ]
```

Details that matter: the namespace and pod selectors of the DNS rule sit in the **same** list element (AND: CoreDNS pods *inside* kube-system; two elements would be OR and allow every pod in kube-system); `k8s-app=kube-dns` is a **pod** label, the namespace is selected by `kubernetes.io/metadata.name`; each rule has its own `ports`, because one `ports` list applies to every peer of that rule; DNS needs UDP and TCP 53.

**Verification.** Clean-room run: `scripts/30-troubleshoot.sh --broken` (verify.sh FAILs at step 3), then `scripts/30-troubleshoot.sh` (applies `fixed-app.yaml`) ends with `PASS` in about 22 s. Then positive and negative checks from throwaway pods that had been Ready for 20 s:

| Pod | Request | Result |
|---|---|---|
| `app=smoke-client` | web by IP | HTTP 200 |
| `app=smoke-client` | web by name | HTTP 200 |
| `app=other` | web by IP | refused |
| `app=other` | web by name | `Resolving timed out` (blocked at DNS) |
| `app=smoke-client` | `quote-api` (another namespace) by IP | refused |
| `app=smoke-client` | `quote-api` by name | name resolved, then refused |

The last row shows the policy is no broader than needed: DNS works, but nothing except `web:80` is reachable.

**A pitfall worth recording: `verify.sh` can print PASS without the DNS rule.** With only the two web rules (no DNS rule) the smoke job still passed here. Pods that had been Ready for 20 s could not resolve names (`Could not resolve host`, or `Resolving timed out`), while a pod whose command ran at the very moment it started could. The explanation that fits all my runs (a mechanism I inferred, not proved) is a startup race: a pod's egress rules reach the firewall a few seconds after it starts, and `curl --retry` reuses the address it resolved on its first attempt, so the smoke job passes if its first lookup wins the race. That is why the first failing `verify.sh` showed `curl: (7)` (name resolved, connection refused) instead of `(6)`. A fix that works only when a lookup is fast enough is fragile, so the DNS rule stays. Two related notes: `kubectl apply` never deletes objects, so a renamed policy leaves the old one behind and `kubectl diff -f` does not show it, which is why the final check is the clean-room run above; and `verify.sh` only checks that `default-deny` exists *by name*, it does not check that it is still deny-all.
