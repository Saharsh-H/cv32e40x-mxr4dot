# Eval-v2 results (copies)

Byte-identical copies of the eval-v2 outputs. They were produced on the GPU PC (RTX 4060 Ti 16 GB) by the
eval-v2 harness in `~/mxr4dot` (= `/home/cadencea8/mxr4dot`), which every result records as eval commit
`1925f9e-dirty`. That code is committed on branch `eval-v2` of the eval repo (commit message "Eval v2 code
as used for the v2 results"). Layout as on the GPU PC: `<modality>/<model>/<mode>.json`.

| Folder / file here | Source on the GPU PC | Contents |
|---|---|---|
| `language/` | `~/mxr4dot/results_v2/language/` | WikiText-2 perplexity: GPT-2, Llama-2-7B, Mistral-7B, Llama-3-8B × 8 formats (key `ppl`, `per_chunk_nll`) |
| `speech/` | `~/mxr4dot/results_v2/speech/` | wav2vec2-base-960h, LibriSpeech test-clean, WER × 8 formats |
| `vision/` | `~/mxr4dot/results_v2/vision/` | ResNet-50, ViT-B/16, DeiT-S/16, ImageNet validation (50,000 images) top-1 × 8 formats |
| `error_analysis/` | `~/mxr4dot/results_v2/error_analysis/` | per-layer operand error (NMSE, dB) per model; `report.md` |
| `zeroshot/` | `~/mxr4dot/results_v2/zeroshot/` | lm-eval 0-shot: GPT-2 8 formats × 5 tasks; Llama-2-7B 5 formats × 4 tasks (boolq failed: CUDA out of memory) |
| `zeroshot_report.md` | `~/mxr4dot/results_v2/zeroshot_report.md` | zero-shot table with paired CIs |
| `ci_report.md` | `~/mxr4dot/results_v2/ci_report.md` | paired bootstrap CIs vs MXFP4R (residue on activations), all modalities, as produced on the GPU PC |
| `other/speech/` | `~/mxr4dot/results_v2_other/speech/` | wav2vec2-base-960h, LibriSpeech test-other, WER × 8 formats |
| `other/ci_report.md` | `~/mxr4dot/results_v2_other/ci_report.md` | CIs for test-other |
| `ci/` | not from the GPU PC | eval-v2 `ci_report.py`, run unchanged in WSL on `language/` (default ref and `--ref mxfp8_e4m3`, 10,000 resamples, seed 0) |
| `index/` | not from the GPU PC's results | `model.safetensors.index.json` of the Llama-2 / Mistral / Llama-3 snapshots eval v2 used (`../configs/snapshot_hashes.txt`) |

The 8 formats: `bf16`/`fp32`, `mxfp4`, `nvfp4`, `m2xfp`, `mxfp4_residual_act_only`, `mxfp4_residual_weight_only`,
`mxfp4_residual`, `mxfp8_e4m3`. Every quantised run leaves the output head unquantised: `lm_head` for
language and speech (`skip_names` in the JSONs), the classifier head for vision (stated in the vision configs).

Not copied: `results_v2/_smoke/` (smoke subsets) and the run logs (`run_v2.log`, `run_remaining.log`).

**Provenance note:** 70 of the 72 accuracy results (all except Mistral-7B and Llama-3-8B `m2xfp`) were written
on 19 Oct 2026, before the last edit of `core/layers.py` (20 Oct, row-chunked weight quantisation, claimed
bit-identical). A re-run check at the committed code is pending.
