### facebook__wav2vec2-base-960h  (WER %, n = 2939 items, 10000 bootstrap resamples)

| mode | WER % | 95% CI | diff vs mxfp4_residual_act_only | 95% CI of diff | CI excludes 0 |
|---|---|---|---|---|---|
| fp32 | 8.568 | [8.208, 8.938] | -4.396 | [-4.676, -4.113] | yes |
| mxfp8_e4m3 | 9.736 | [9.34, 10.13] | -3.229 | [-3.479, -2.976] | yes |
| mxfp4_residual | 8.895 | [8.525, 9.267] | -4.069 | [-4.34, -3.799] | yes |
| mxfp4_residual_act_only | 12.96 | [12.51, 13.43] | — | — | — |
| mxfp4_residual_weight_only | 19.41 | [18.79, 20.05] | +6.45 | [+6.019, +6.897] | yes |
| m2xfp | 17.52 | [16.94, 18.12] | +4.553 | [+4.16, +4.959] | yes |
| nvfp4 | 15.48 | [14.94, 16] | +2.516 | [+2.188, +2.849] | yes |
| mxfp4 | 32.31 | [31.43, 33.17] | +19.34 | [+18.64, +20.07] | yes |
