# AI usage

<!-- TEMPLATE. The task: "We expect heavy AI usage. What we screen for is whether you can verify, correct, and own AI
     output", and "we will ask you to walk through your code live either way". Everything below must be TRUE and in
     your own words. The candidate cases are real events from the work with evidence you can re-run; pick the ones
     you can explain, and say honestly who noticed what (the AI itself noticed some of them). -->

## Tools and what they were used for

<!-- YOUR TEXT: Claude Code (the VS Code extension; models Opus 5.5 and Sonnet 5.5) was the main assistant. Say for
     which parts: planning/analysis (with a custom analyst agent), the harness and scripts, the chart, the Go service,
     the troubleshooting guidance, the load-test tooling, the docs. Say what you did yourself (for example diagnosing
     the Part 3 faults by hand, choosing the scope, deciding to cut Parts 4 and 5, deciding between options). -->

## How I verified AI output

<!-- YOUR TEXT (3-5 sentences, the habits that came out of the cases below). Facts that fit: nothing counted as done
     without a command and its output; claims were tested with a control experiment that could fail (a hard spread
     with and without `nodeTaintsPolicy: Honor`; a Pod Security check with a deliberately bad Deployment); chart
     values were checked against `helm show values` after one invented key; "it ran" was never treated as "the
     setting took effect". -->

## Representative prompts

<!-- Pick 2-3 prompts that really moved the work forward, in your own wording (they were written in Vietnamese: keep
     the original and add a translation if you like). Copy them from your history; do not reconstruct them. Say what
     each one produced. Candidate TYPES (check the real wording before using any):
     - the one that loaded the plan and context at the start of the work
     - "verify this before moving on" style prompts (for example before the reclaim drill)
     - a prompt that made the AI explain something you then re-ran yourself (for example the two-ended NetworkPolicy
       reasoning and the DNS experiment) -->

1. <!-- prompt -->
   - Result: <!-- what it moved forward -->
2. <!-- prompt -->
   - Result: <!-- -->
3. <!-- optional -->
   - Result: <!-- -->

## Where the AI was wrong or suboptimal, and how it was caught

<!-- REQUIRED: at least one. Choose from the candidates below and write 4-6 sentences each in your own words:
     what the AI said or built, what made it suspicious, the exact command that showed the truth, and what you changed.
     Be exact about WHO caught it. -->

| # | What went wrong | How it showed | Evidence you can re-run | Fix |
|---|---|---|---|---|
| 1 | **Placement design ignored HPA scale-down.** Topology spread only acts when a pod is placed; the ReplicaSet picked pods to delete without looking at it, so 2 of 3 scale-downs left 3 spot + 0 on-demand, against "always at least one on-demand". | the load-test timeline records the on-demand count; the surviving pods were all spot | `loadtest/evidence/stress/hpa-timeline.tsv`; `docker compose exec toolbox kubectl -n quote-api get pods -o wide` | descheduler (`descheduler/values.yaml`); recovery measured at 51 s |
| 2 | **The service never saturated.** `/api/quote` spun until 100 ms of wall clock had passed instead of doing a fixed amount of work, so a pod limited to 0.5 core served 40 req/s with no errors. | the baseline looked impossible: 40 req/s x 100 ms of CPU is 4 cores on a 0.5-core pod | `scratch`-style baseline in the knowledge notes; the stress run now collapses at ~5 req/s per pod | fixed work, calibrated at start-up (`app/main.go`) |
| 3 | **An invented Helm key.** `applicationSet.enabled: false` does not exist in the chart; Helm silently ignores unknown keys, so everything "worked". | `kubectl get deploy` still showed the applicationset controller running | compare `helm get values argocd` with `helm show values argo/argo-cd --version 10.10.1` | `applicationSet.replicas: 0`; values checked against the chart from then on |
| 4 | **Wrong expectation about the NetworkPolicy/DNS.** The AI expected the smoke test to fail on DNS and then, when `verify.sh` passed without a DNS rule, proposed two explanations ("same node is not filtered", "wait for the sync") that experiments disproved. | a pod that waited 20 s could not resolve names, a pod whose command ran at start-up could | the IP-versus-name curl experiment in `TROUBLESHOOTING.md` section 8 | explicit DNS egress rule; the pass is a start-up race |
| 5 | **Confident statements that were not verified**: "verified empirically in the reclaim drill" before any drill existed; "the GHCR package is private by default"; "k3d writes 0.0.0.0" (it was `host.docker.internal`); `matchLabelKeys` "GA ~1.33" (the cluster says beta). | re-reading the claim before committing, and `gh api`, `kubectl explain`, `k3d kubeconfig get` | the notes in `VERSIONS.md` that now say what is and is not verified | the claims were corrected or removed |
| 6 | **Resource limits set without measuring**: Grafana's 256 Mi memory limit OOM-killed it 14 times in two hours (it needs ~520 Mi). | the UI showed "failed to load its application files"; the pod had `restarts=14` | `kubectl describe pod` -> `Last State: OOMKilled` | limit 768 Mi, request 256 Mi |
| 7 | **Plan assumptions**: the plan treated this machine as unknown and pointed at a path that did not exist. | the first hardware and file checks | -- | corrected before any work |
| 8 | **An operational slip**: the AI started the stress run without `PROFILE=stress`, so the default profile overwrote the first load run's raw evidence. | the log said `profile=load` | `loadtest/evidence/load/first-run-console.txt` is what remains of that run | stopped it, kept the console output, re-ran |

<!-- YOUR TEXT: for the 1-3 cases you pick, tell it as a short story. Do not include a case you cannot walk through. -->

## What I would not trust the AI with

<!-- YOUR TEXT (2-3 sentences, optional but strong): for example claims about behaviour it has not tested (scheduler
     internals, version-specific feature status), numbers it recalls, and configuration keys it types from memory. -->
