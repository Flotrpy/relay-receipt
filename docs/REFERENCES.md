# References

Research papers and similar projects for the project ideas we've explored. Every arXiv number below was checked against arXiv on November 11, 2026.

- [Receipt](#receipt) — audits AI API providers (current idea)
- [Pedigree](#pedigree) — finds hidden changes in modified AI models
- [Tripline](#tripline) — blocks multi-step attacks inside the Linux kernel

---

## Receipt

### Core papers (one per check)

| Check | Paper | Link |
|---|---|---|
| Hidden prompt (billed tokens vs. real prompt) | Token Counts Are Not Model Lineage: A Frozen-Threshold Holdout Study of Black-Box LLM API Fingerprinting (Aug 2026) | [2608.29930](https://arxiv.org/abs/2608.29930) |
| Token inflation | The More It Says, the More You Pay: A Black-Box Audit of Provider-Side Token Inflation in LLM Services (Sep 2026) | [2609.20370](https://arxiv.org/abs/2609.20370) |
| Model swap (tool-call fingerprint) | AgentProv: Auditing Agentic LLM API Providers via Tool-use Policy Probes (Aug 2026) | [2609.00052](https://arxiv.org/abs/2609.00052) |
| Hidden middleman (cache timing) | Uncovering and Understanding Hidden Dependencies in the LLM API Reseller Ecosystem via Prefix-Cache Side Channels — "CacheTracer" (Aug 2026) | [2608.20732](https://arxiv.org/abs/2608.20732) |

### Supporting papers

| Topic | Paper | Link |
|---|---|---|
| Model swap | Model Equality Testing: Which Model Is This API Serving? (Oct 2024) | [2410.20247](https://arxiv.org/abs/2410.20247) |
| Model swap | Are You Getting What You Pay For? Auditing Model Substitution in LLM APIs (Apr 2025) | [2504.04715](https://arxiv.org/abs/2504.04715) |
| Model swap | Auditing Black-Box LLM APIs with a Rank-Based Uniformity Test (Jun 2025) | [2506.06975](https://arxiv.org/abs/2506.06975) |
| Billing | Invisible Tokens, Visible Bills: The Urgent Need to Audit Hidden Operations in Opaque LLM Services (May 2025) | [2505.18471](https://arxiv.org/abs/2505.18471) |
| Billing | Auditing Pay-Per-Token in Large Language Models (Oct 2025) | [2510.05181](https://arxiv.org/abs/2510.05181) |
| Billing | Token Inflation: How Dishonest Providers Can Overcharge for Large Language Model Usage (May 2026) | [2605.30040](https://arxiv.org/abs/2605.30040) |
| Gateways | Behavioral Consistency and Transparency Analysis on Large Language Model API Gateways — "GateScope", 1,010 gateways (Apr 2026) | [2604.21083](https://arxiv.org/abs/2604.21083) |
| Malicious relays | Your Agent Is Mine: Measuring Malicious Intermediary Attacks on the LLM Supply Chain (Apr 2026) | [2604.08407](https://arxiv.org/abs/2604.08407) |
| Verifiable audits | IMMACULATE: A Practical LLM Auditing Framework via Verifiable Computation (Feb 2026) | [2602.22700](https://arxiv.org/abs/2602.22700) |

### Similar projects on GitHub

Stars as of November 11, 2026.

| Project | Stars | What it covers | Overlap with Receipt |
|---|---|---|---|
| [toby-bridges/api-relay-audit](https://github.com/toby-bridges/api-relay-audit) | 910 | Hidden prompt injection (token-delta method), model substitution signals (self-ID, latency, channel fingerprints), tool-call rewriting, context truncation, Web3 wallet checks | **High.** Covers the hidden-prompt check and a basic model-swap check |
| [maoyuki31-dev/llm-api-audit-kit](https://github.com/maoyuki31-dev/llm-api-audit-kit) | 1 | Testing protocols for behavior fingerprints, probability fingerprints, and token billing; mostly documents, code partly finished | Medium (billing) |
| [sunblaze-ucb/llm-api-audit](https://github.com/sunblaze-ucb/llm-api-audit) | 14 | Research code for paper 2504.04715: classifiers and identity prompting to catch quantized or swapped models | Medium (model swap, research code) |
| [i-gao/model-equality-testing](https://github.com/i-gao/model-equality-testing) | — | Research code for 2410.20247: MMD statistical test plus 1M-completion dataset | Medium (model swap, research code) |
| [xyzhu123/RUT](https://github.com/xyzhu123/RUT) | — | Research code for 2506.06975: rank-based test | Medium (model swap, research code) |
| [Networks-Learning/token-audit](https://github.com/Networks-Learning/token-audit) | — | Research code for auditing hidden reasoning-token counts | Medium (billing, research code) |
| [guo-yanpei/Immaculate](https://github.com/guo-yanpei/Immaculate) | — | Research code for 2602.22700 | Low |
| [MoonshotAI/K2-Vendor-Verifier](https://github.com/MoonshotAI/K2-Vendor-Verifier) | — | Tool-call accuracy across Kimi K2 providers | Low (one model, quality not honesty) |
| [Mohamed7415/fpverify](https://github.com/Mohamed7415/fpverify) | — | Behavioral fingerprint check for relays | Medium (model swap) |
| [mintesnot-teshome/llm-verify](https://github.com/mintesnot-teshome/llm-verify) | — | 32 forensic prompts for model identity | Medium (model swap) |
| [rigprobe/affordable-llm-api-audits](https://github.com/rigprobe/affordable-llm-api-audits) | 0 | Published audit results for low-cost API resellers | Low (results, not a tool) |

**Not found in any project:** the token inflation single-probe audit (2609.20370) and the CacheTracer cache-timing middleman check (2608.20732).

---

## Pedigree

Full feature table and roadmap: https://claude.ai/artifact/7PeYYwcs563kNQywZCQDec

### Core

| Paper | Link |
|---|---|
| Activation Differences Reveal Backdoors: A Comparison of SAE Architectures | [2605.07324](https://arxiv.org/abs/2605.07324) |
| Watch the Weights: Unsupervised monitoring and control of fine-tuned LLMs | [2508.00161](https://arxiv.org/abs/2508.00161) |
| LoRAScan: Detecting Backdoor Prompts in Low-Rank Adapters | [2608.06795](https://arxiv.org/abs/2608.06795) |
| Who Built This Model? Tracing LLM Lineage via Spectral Fingerprints in Weight Space | [2608.07786](https://arxiv.org/abs/2608.07786) |

### By feature

| Feature | Papers |
|---|---|
| Parent Set | [2602.00772](https://arxiv.org/abs/2602.00772) Provable Model Provenance Set · [2512.03620](https://arxiv.org/abs/2512.03620) SELF |
| API Mode | [2502.00706](https://arxiv.org/abs/2502.00706) Model Provenance Testing |
| Abliteration Detector | [2406.11717](https://arxiv.org/abs/2406.11717) Refusal Is Mediated by a Single Direction · [2506.00085](https://arxiv.org/abs/2506.00085) COSMIC |
| Narrow-Change Finder | [2603.04426](https://arxiv.org/abs/2603.04426) Delta-Crosscoder |
| Side-Effect Forecast | [2507.21084](https://arxiv.org/abs/2507.21084) MNEME · [2607.17427](https://arxiv.org/abs/2607.17427) Abliteration Is Not a Scalpel |
| Delta-Guided Trigger Search | [2602.03085](https://arxiv.org/abs/2602.03085) The Trigger in the Haystack · [2606.31309](https://arxiv.org/abs/2606.31309) CSO-LLM |
| Sequence-Lock Alarm | [2508.01365](https://arxiv.org/abs/2508.01365) ConfGuard |
| Merge Inspector | [2411.16746](https://arxiv.org/abs/2411.16746) LoBAM · [2403.00108](https://arxiv.org/abs/2403.00108) LoRATK · [2608.09490](https://arxiv.org/abs/2608.09490) When Do Task Vectors Interfere? |
| Auditor Agent | [2510.16255](https://arxiv.org/abs/2510.16255) Detecting Adversarial Fine-tuning with Auditing Agents |
| Safety Restore | [2402.11746](https://arxiv.org/abs/2402.11746) RESTA · [2511.09880](https://arxiv.org/abs/2511.09880) EnchTable |
| Protect | [2609.16204](https://arxiv.org/abs/2609.16204) Decoy Direction Optimization · [2608.18093](https://arxiv.org/abs/2608.18093) Refusal Aliases |
| Watch Mode | [2511.15992](https://arxiv.org/abs/2511.15992) Sleeper Agents via Semantic Drift |

### Problem evidence

| Paper | Link |
|---|---|
| Visible but Not Yet Curatable (only 6.1% of open-model records verifiable) | [2608.28819](https://arxiv.org/abs/2608.28819) |
| ShadowPickle: Evading ML Model Scanners | [2607.17503](https://arxiv.org/abs/2607.17503) |
| SilentCall: Hidden Tool-Call Backdoors in Open-Weight Agents | [2609.32021](https://arxiv.org/abs/2609.32021) |
| Detecting Safety Training Modification via Activation Analysis (related prior work) | [2608.05578](https://arxiv.org/abs/2608.05578) |

### Similar projects

- [Cisco Model Provenance Kit](https://helpnetsecurity.com/2026/04/30/cisco-ai-model-provenance-kit) — finds a model's original
- [modelDNA](https://pypi.org/project/modeldna/) — weight-based lineage
- [dreamfast/abliterlitics](https://github.com/dreamfast/abliterlitics) — abliteration forensics toolkit
- [Picklescan](https://pypi.org/project/picklescan/), [ModelScan](https://github.com/mehrinkiani/modelscan) — malware in model files
- [PEFTGuard](https://tianshuocong.github.io/files/sp25-peftguard.pdf) — LoRA backdoor detector and benchmark

---

## Tripline

| Paper | Link |
|---|---|
| Enforcement of In-Kernel Stateful Security Policies via eBPF — "BPFence" (Sep 2026) | [2609.13930](https://arxiv.org/abs/2609.13930) |
| AgentLoupe: Kernel-Resident Semantic Causal Labels for AI Agent Observability (Oct 2026) | [2610.23233](https://arxiv.org/abs/2610.23233) |
| Heimdall: Formally Verified Automated Migration of Legacy eBPF Programs to Rust (May 2026) | [2605.25411](https://arxiv.org/abs/2605.25411) |
| eBPF Security in the Wild: Structural Concentration, Failure Mechanisms, and Discovery Gaps (Aug 2026) | [2609.26254](https://arxiv.org/abs/2609.26254) |

### Similar projects

- [Falco](https://falco.org/) — single-event rules; sequences only in Sysdig's paid extension
- [Tetragon](https://github.com/cilium/tetragon) — in-kernel enforcement with YAML rules
- [owLSM (Cybereason)](https://awesome.ecosyste.ms/projects/github.com%2FCybereason-Public%2FowLSM) — eBPF agent with a stateful Sigma rules engine
- [StepSecurity Harden-Runner](https://github.com/step-security/harden-runner) — network monitoring for GitHub Actions
