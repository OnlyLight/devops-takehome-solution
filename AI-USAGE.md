# AI usage

## Tools and what they were used for

Claude Code in VS Code (Sonnet 5.5) was my only AI assistant: planning with a custom analyst agent, the harness and scripts, the Helm chart, the Go service, the troubleshooting guidance, the load-test tooling and first drafts of the docs. I chose the scope (Part 6 as the track), decided between design options, and re-ran commands to check what the AI reported. For Part 6 I re-ran the queries and calculations myself, and the AI corrected my mistakes (for example I divided the load by 3 pods twice).

## How I verified AI output

Nothing counted as done without a command and its output. Claims were tested with a control experiment that could fail (a hard spread with and without `nodeTaintsPolicy: Honor`; a Pod Security check with a deliberately bad Deployment), chart values were checked against `helm show values`, and numbers in the docs must point to committed evidence.

## Representative prompts

1. *"Study Part 6 (monitoring, load test, observability) of the ITV DevOps take-home with me. I want to understand it deeply enough to answer a reviewer live, so explain step by step, make me run the commands myself, and point out what is verified versus assumed. Do not write my docs for me."* Result: a step-by-step walk with experiments I ran myself and every claim marked verified or assumed; it exposed the sourcing problem in case 9.
2. *"bỏ qua phần bottleneck đc ko.. vì nó là phần đc làm qua folder scratch"* (can I skip the bottleneck section, its numbers came from the scratch folder?) Result: the AI checked the task text instead of agreeing, found that item 6 requires it, and we kept a short version that claims only what the committed evidence shows.
3. *"Help me explain Part 6 step by step.. I want to understand clearly everything related to monitoring"* Result: a layered map of the monitoring stack; my follow-up questions were answered by checking the cluster, not from memory.

## Where the AI was wrong or suboptimal, and how it was caught

| # | What went wrong | How it showed / evidence | Fix |
|---|---|---|---|
| 1 | **Placement ignored HPA scale-down.** Topology spread only acts when a pod is placed, so 2 of 3 scale-downs left 3 spot + 0 on-demand. | the on-demand count in `loadtest/evidence/stress/hpa-timeline.tsv` | descheduler; recovery measured at 51 s |
| 2 | **The service never saturated.** `/api/quote` spun for 100 ms of wall clock, so a 0.5-core pod served 40 req/s with no errors. | the baseline looked impossible (40 req/s x 100 ms is 4 cores); now `loadtest/evidence/baseline.txt` collapses at 5 req/s per pod | fixed work calibrated at start-up (`app/main.go`) |
| 3 | **An invented Helm key.** `applicationSet.enabled: false` does not exist; Helm silently ignored it. | `kubectl get deploy` still showed the controller; compare `helm get values argocd` with `helm show values argo/argo-cd --version 10.10.1` | `applicationSet.replicas: 0` |
| 4 | **Wrong NetworkPolicy/DNS expectation.** Two explanations for why `verify.sh` passed without a DNS rule were disproved by experiments. | the curl experiment in `TROUBLESHOOTING.md` section 8 | explicit DNS egress rule |
| 5 | **Confident but unverified statements**: "verified in the reclaim drill" before any drill; "GHCR package is private by default"; "k3d writes 0.0.0.0"; `matchLabelKeys` "GA ~1.33". | re-reading before committing, `gh api`, `kubectl explain`, `k3d kubeconfig get` | corrected or removed (`VERSIONS.md`) |
| 6 | **Limits set without measuring.** Grafana's 256 Mi limit OOM-killed it 14 times in two hours. | `kubectl describe pod` shows `OOMKilled`, `restarts=14` | limit 768 Mi |
| 7 | **Plan assumptions** about this machine and a path that did not exist. | the first hardware and file checks | corrected before any work |
| 8 | **An operational slip.** The stress run started without `PROFILE=stress` and overwrote the first load run's raw evidence. | the log said `profile=load`; `loadtest/evidence/load/first-run-console.txt` is what remains | stopped, kept the console output, re-ran |
| 9 | **Numbers that could not be re-checked.** A k6 comment said 1500 ms is "an order of magnitude below the timeouts" (it is 6.7x); the baseline, bottleneck and "24 req/s" figures came from the git-ignored `scratch/`; a re-run gave 0% errors at 5 req/s per pod, not the 21% in my notes. | reviewing `LOADTEST.md` against committed evidence (`git check-ignore -v scratch`) | baseline script and output committed (`loadtest/`), comments corrected, unsourced figures marked as hypotheses |

**Case 3 as a story.** The AI wrote `applicationSet.enabled: false` in `argocd/values.yaml`. The script exited 0 and ArgoCD showed Synced and Healthy, but `kubectl -n argocd get deploy` still listed the applicationset controller as running. The AI noticed this while answering a question about Argo's polling; I then re-ran the two helm commands myself and saw that the chart has no such key, so Helm had silently ignored it. I now check every values key against `helm show values`.

## What I would not trust the AI with

Claims about behaviour it has not tested (scheduler internals, version-specific feature status), numbers it recalls from memory, and configuration keys it types from memory. Each of these was wrong at least once here, mostly caught by running a command.
