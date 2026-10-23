## A. Which operand dominates plain-MXFP4 error, and where should residue go?

Layer-averaged NMSE of the layer output in dB (more negative = smaller error).

| model | e_W MXFP4 | e_A MXFP4 | dominant | full MXFP4 | residue-on-A | residue-on-W | predicted side | accuracy: better side | match |
|---|---|---|---|---|---|---|---|---|---|
| deit_s16 | -20.3 | -19.5 | A | -16.7 | -20.2 | -19.5 | A (output error says A) | A | yes |
| gpt2 | -19.3 | -17.8 | A | -15.2 | -19.2 | -17.7 | A (output error says A) | A | yes |
| llama2_7b | -21.2 | -20.2 | A | -17.3 | -21.0 | -20.1 | A (output error says A) | A | yes |
| llama3_8b | -21.0 | -20.0 | A | -17.1 | -20.9 | -19.9 | A (output error says A) | A | yes |
| mistral_7b | -20.8 | -19.5 | A | -16.7 | -20.6 | -19.4 | A (output error says A) | A | yes |
| resnet50 | -20.1 | -20.4 | W | -17.0 | -20.0 | -20.3 | W (output error says W) | W | yes |
| vit_b16 | -21.5 | -20.5 | A | -17.6 | -21.3 | -20.4 | A (output error says A) | A | yes |
| wav2vec2 | -20.8 | -19.8 | A | -17.0 | -20.7 | -19.7 | A (output error says A) | A | yes |

## B. Operand error per format (reviewer R1.5)

Each cell: e_W / e_A in dB - error from quantising only the weights / only the activations with that format.

| model | MXFP4 | MXFP4 2-block residue | NVFP4 | M2XFP4 | MXFP8-E4M3 |
|---|---|---|---|---|---|
| deit_s16 | -20.3 / -19.5 | -38.1 / -37.0 | -22.7 / -23.2 | -23.9 / -22.3 | -32.0 / -31.6 |
| gpt2 | -19.3 / -17.8 | -37.3 / -35.5 | -22.3 / -22.1 | -23.2 / -20.5 | -31.1 / -30.4 |
| llama2_7b | -21.2 / -20.2 | -39.3 / -38.0 | -23.8 / -23.9 | -24.9 / -23.0 | -33.2 / -32.6 |
| llama3_8b | -21.0 / -20.0 | -39.1 / -37.8 | -23.8 / -23.9 | -24.9 / -22.9 | -33.0 / -32.5 |
| mistral_7b | -20.8 / -19.5 | -38.9 / -37.2 | -23.7 / -23.8 | -24.7 / -22.5 | -32.7 / -32.2 |
| resnet50 | -20.1 / -20.4 | -37.6 / -37.9 | -23.9 / -24.9 | -24.4 / -24.9 | -32.0 / -31.7 |
| vit_b16 | -21.5 / -20.5 | -39.2 / -37.9 | -24.2 / -24.8 | -25.3 / -23.5 | -33.5 / -32.7 |
| wav2vec2 | -20.8 / -19.8 | -38.7 / -37.2 | -23.9 / -24.2 | -24.7 / -22.9 | -33.0 / -32.4 |

