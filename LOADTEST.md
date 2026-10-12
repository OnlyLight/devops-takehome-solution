# Load test: results and what they mean

<!-- TEMPLATE. The numbers in the tables are measured (source in the last column); the prose is yours.
     Replace every "YOUR TEXT" comment with 2-4 sentences in your own words, then delete these comments.
     Target: about one page. Every claim you make must be something you can explain out loud. -->

## Setup

<!-- YOUR TEXT (2-3 sentences): the machine (Latitude 5421, i7-11850H, Docker VM given 9.7 GB / 16 CPUs), that the
     cluster is k3d with 1 server + 4 agents, that k6 runs in the toolbox container and goes through the Ingress
     (Traefik), and that k6, Prometheus, Grafana and the cluster all share the same Docker VM. -->

Run it: `./scripts/run-all.sh`, or just this part: `PROFILE=load docker compose exec toolbox bash /scripts/60-loadtest.sh`
(profiles: `smoke` ~30 s, `load` ~6 min, `stress` ~12 min). Evidence is written to `loadtest/evidence/<profile>/`.

## Baseline and thresholds

<!-- YOUR TEXT (3-4 sentences): how you measured one pod on its own (no HPA, same image and limits, through Traefik,
     fixed arrival rates), and what the numbers say. Say why the open model (arrival rate) was chosen over a fixed
     number of virtual users. Then justify EACH threshold below from these numbers. -->

| One pod, 500m CPU limit | Measured |
|---|---|
| Stable up to | 4 req/s per pod: p50 178-209 ms, p95 183-219 ms, 0 errors |
| Collapses at | 5 req/s per pod: p95 about 10 s, 21% errors |
| Latency of a single request | about 200 ms (the work is 100 ms of CPU, the 500m limit allows 50 ms per 100 ms period) |

| Threshold | Value | Why this value (YOUR TEXT) |
|---|---|---|
| `http_req_failed` | rate < 1% | <!-- healthy runs had 0%; what did saturation produce? --> |
| `http_req_duration` p95 | < 500 ms | <!-- compare with the stable p95 and the p95 seen while the HPA scaled out --> |
| `http_req_duration` p99 | < 1500 ms | <!-- why a looser tail threshold? what was seen at collapse? --> |

The smoke profile with `P95_MS=50` fails on purpose, which shows the thresholds can fail.

## Results

| Run | Load | Errors | p95 | p99 | HPA | Alert | Source |
|---|---|---|---|---|---|---|---|
| `load` #1 | 3 to 8 to 20 req/s, 6 min | 0 / 4049 | 437.9 ms | 516.5 ms | 3 to 4 to 6 to 8 | silent | `evidence/load/first-run-console.txt` |
| `load` #2 | same | 0 / 4049 | 413.8 ms | 455.5 ms | 3 to 4 to 5 to 6 to 8 | silent | `evidence/load/` |
| `stress` | 10 to 50 req/s, 8 min | 77% (client timeouts) | at the 5 s histogram ceiling | | 3 to 8 (max) | pending, then firing | `evidence/stress/` |

At the peak the replicas were 5 spot + 3 on-demand, never on the GPU or control-plane node (`hpa-timeline.tsv`).
The first `load` run's screenshot: `docs/img/grafana-load.png`.

<!-- YOUR TEXT (2-3 sentences): what the scale-out looked like (when it started, how long until 8 replicas) and that
     the new replicas still respected the spot/on-demand placement (the extras spill to on-demand, why?). -->

## Maximum sustainable RPS and the bottleneck

| Measured with 8 replicas | |
|---|---|
| Sustainable with p95 < 500 ms | about 20 req/s (the `load` plateau) |
| Server-side ceiling | about 24 req/s (completed requests per second peaked here), collapsing beyond about 30 req/s |
| Theory (8 pods x 4 req/s) | 32 req/s, so about 75% was reached |
| CPU per pod at 40 req/s | about 0.48 core of the 0.5 limit; CFS throttled in 90-99% of periods |
| Traefik CPU | at most 0.14 core |
| HPA | already at `maxReplicas: 8` (CPU 150-165% of the 300m request) |

<!-- YOUR TEXT (3-4 sentences): the bottleneck is ... (app CPU limit? node capacity? ingress?) and the evidence for
     it; why Traefik and the nodes are NOT the bottleneck. Say plainly what you did NOT investigate: why only about
     75% of the theoretical 32 req/s was reached, and why throughput fell (24 to 4-11 req/s) instead of staying at the
     ceiling once overloaded. -->

## What I would scale first in production, and why

<!-- YOUR TEXT (3-5 sentences). Points to cover, in the order you think is right:
     - the CPU limit (it doubled the latency of a single request and is where throttling happens)
     - maxReplicas (the HPA ran out of headroom) and minReplicas for a known peak (the first scale-out came about
       80 s after the load rose: 15 s metric scrape + HPA step + pod start)
     - the work per request itself
     - Traefik (a single replica here: not a bottleneck, but a single point of failure for incoming traffic) -->

## Alert threshold

<!-- YOUR TEXT (one paragraph, as the task asks): why `QuoteApiHighLatency` (p95 > 0.5 s for 2 minutes) and not a
     5xx-ratio alert; why 0.5 s and why `for: 2m`; what you observed (silent at p95 about 440 ms during `load`;
     pending at 16:06:49, firing at 16:08:48 and back to inactive at 16:14:21 during `stress`).
     Facts to use: when the service saturated it kept answering 200, only very slowly, and the failures were client
     timeouts; with no traffic `histogram_quantile` is NaN, and `NaN > 0.5` is false, so it does not fire at idle.
     The cluster has no Alertmanager (cut on purpose to save memory): the alert is visible in Prometheus, nobody is paged. -->

## Limits of this measurement

<!-- YOUR TEXT (3-5 bullets, honest). Candidates: one machine and one configuration; the load generator shares the
     Docker VM with the cluster; Prometheus histogram quantiles are interpolated inside buckets (p95 on Grafana is an
     estimate; k6's numbers are exact); the largest histogram bucket is 5 s; two `load` runs and one `stress` run, not a
     statistical sample; the first `load` run's raw files were overwritten by a mistaken run (its console output is kept). -->
