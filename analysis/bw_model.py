"""Task 5: memory traffic of MX dot products - two separate regimes, never mixed.

REGIME A - this system, measured (CV32E40X + MX coprocessor, task-3 K=4096 loops)
  python3 analysis/bw_model.py regime-a <loop.json> [<loop.json> ...]
  Each <loop.json> comes from tb/scripts/loop_report.py --json-out ... --meta
  format=<mxfp4|mxfp8|mxfp4r>,dwait=<n>. For every (format, NACC, dwait) it prints
  the bytes per cycle the loop actually reads (weights, activations), the share of
  what the CV32E40X data port can supply (32-bit OBI, at most one access per
  cycle: 4 B/cycle, 1 access/cycle), and - when several dwait settings are given -
  how the measured extra cycles compare with dwait x accesses (fully additive?).

REGIME B - analytic decode model, NOT this system (compute assumed not to limit)
  python3 analysis/bw_model.py regime-b analysis/configs/<model>.json [...]
        [--ctx 512,4096] [--bw 17e9,50e9]
  <model>.json = the exact Hugging Face config.json used by eval v2 (copied from
  the GPU PC's HF cache, not retyped). Batch-1 autoregressive decode: per token
  every quantised linear layer is one GEMV whose weights are streamed from DRAM
  once; the decode rate is set by DRAM bandwidth alone. Primary output: bytes per
  token per format (format ratios do not depend on bandwidth). Tokens/s are
  printed at the --bw points and are illustrative only.

Layer policy (eval v2, frameworks/language.py): every nn.Linear / HF Conv1D is
quantised except lm_head; embeddings, norms, biases and lm_head stay BF16. The KV
cache is BF16 for every format and read in full once per token at context length
L (clamped to the model's maximum position).
"""
import argparse
import json
import sys

# ---------------------------------------------------------------------------
# Bits per element, scales included (OCP block 32 unless noted). Regime B.
# ---------------------------------------------------------------------------
FORMATS = [  # name, bits per weight, bits per activation, note
    ('BF16',               16.0,  16.0, 'reference'),
    ('MXFP8-E4M3',          8.25,  8.25, ''),
    ('MXFP4',               4.25,  4.25, ''),
    ('NVFP4',               4.5,   4.5,  'FP8 scale per 16; per-tensor FP32 scale ignored'),
    ('M2XFP4',              4.5,   4.5,  '8 metadata bits per 16 elements'),
    ('MXFP4R (residue A)',  4.25,  8.5,  'implemented in hardware'),
    ('MXFP4R (residue W)',  8.5,   4.25, ''),
    ('MXFP4R (residue both)', 8.5, 8.5,  ''),
]

# ---------------------------------------------------------------------------
# Regime A: what one K-element dot product reads, from the data layout
# (tb/scripts/gen_loop_data.py) and the kernels (sw/<fmt>/kernel.S).
# bytes: (weight bytes incl. scales, activation bytes incl. scales) per K elements
# accesses: data-port accesses per K elements (lw + lbu in the loop body)
# ---------------------------------------------------------------------------
def loop_traffic(fmt, k):
    nblk = k // 32
    if fmt == 'mxfp4':    # 4 lw per mxfused (16 elem); 2 lbu per block
        return (k // 2 + nblk, k // 2 + nblk, (k // 16) * 4 + 2 * nblk)
    if fmt == 'mxfp8':    # 4 lw per mxfused (8 elem); 2 lbu per block
        return (k + nblk, k + nblk, (k // 8) * 4 + 2 * nblk)
    if fmt == 'mxfp4r':   # 6 lw per pair (16 elem: A, W, AR); 3 lbu per block
        return (k // 2 + nblk, 2 * (k // 2 + nblk), (k // 16) * 6 + 3 * nblk)
    raise ValueError(fmt)


PORT_BYTES, PORT_ACCESSES = 4.0, 1.0


def regime_a(paths):
    runs = [json.load(open(p)) for p in paths]
    print('REGIME A - this system (CV32E40X + MX coprocessor), MEASURED loop cycles (MARK).')
    print('Memory: data port with +dwait response latency (0 = ideal single-cycle); instruction')
    print('port ideal. Pre-quantised activations; runtime activation quantisation not counted.')
    print(f'Data port supplies at most {PORT_BYTES:g} B/cycle and {PORT_ACCESSES:g} access/cycle.\n')
    hdr = (f'{"format":8}{"variant":8}{"dwait":>6}{"cycles":>8}{"elem/cyc":>9}{"W B/cyc":>9}{"A B/cyc":>9}'
           f'{"tot B/cyc":>10}{"% bytes":>8}{"acc/cyc":>8}{"% slots":>8}{"dCyc":>7}{"w*acc":>7}{"ratio":>7}')
    print(hdr)
    base = {}
    for r in runs:
        for rid, reg in r['regions'].items():
            if reg['mx']:
                base.setdefault((r['format'], rid), {})[int(r['dwait'])] = reg['cycles']
    for r in sorted(runs, key=lambda r: (r['format'], int(r['dwait']))):
        k, fmt, w = r['k'], r['format'], int(r['dwait'])
        wb, ab, acc = loop_traffic(fmt, k)
        for rid, reg in sorted(r['regions'].items()):
            if not reg['mx']:
                continue
            c = reg['cycles']
            var = {'10': 'NACC=1', '20': 'NACC=4'}.get(str(rid), str(rid))
            d = c - base[(fmt, rid)].get(0, c)
            extra = f'{d:7d}{w * acc:7d}{(d / (w * acc)) if w else 0:7.2f}' if 0 in base[(fmt, rid)] and w else f'{"":21}'
            print(f'{fmt:8}{var:8}{w:6d}{c:8d}{k / c:9.3f}{wb / c:9.3f}{ab / c:9.3f}{(wb + ab) / c:10.3f}'
                  f'{100 * (wb + ab) / c / PORT_BYTES:7.1f}%{acc / c:8.3f}{100 * acc / c / PORT_ACCESSES:7.1f}%{extra}')
    print('\ndCyc = cycles - cycles at dwait 0; w*acc = dwait x data accesses; ratio = dCyc / (w*acc)')
    print('(ratio 1 = every wait cycle adds to the loop; < 1 = partly overlapped).')


# ---------------------------------------------------------------------------
# Regime B
# ---------------------------------------------------------------------------
def model_shapes(cfg):
    """-> dict with the per-token GEMV list [(K_in, N_out)], BF16 element counts,
    KV elements per token of context, max context."""
    mt = cfg.get('model_type')
    if mt == 'gpt2':
        h, nl, nh, v = cfg['n_embd'], cfg['n_layer'], cfg['n_head'], cfg['vocab_size']
        inter = cfg.get('n_inner') or 4 * h
        gemv = [(h, 3 * h), (h, h), (h, inter), (inter, h)] * nl          # c_attn, attn c_proj, c_fc, mlp c_proj
        bias = (3 * h + h + inter + h) * nl
        norms = (2 * 2 * h) * nl + 2 * h                                   # ln_1, ln_2 (w + b), ln_f
        kv_dim = h                                                         # n_kv_heads * head_dim
        max_pos = cfg['n_positions']
    elif mt in ('llama', 'mistral'):
        h, nl, nh, v = cfg['hidden_size'], cfg['num_hidden_layers'], cfg['num_attention_heads'], cfg['vocab_size']
        inter = cfg['intermediate_size']
        nkv = cfg.get('num_key_value_heads', nh)
        hd = cfg.get('head_dim') or h // nh
        gemv = [(h, nh * hd), (h, nkv * hd), (h, nkv * hd), (nh * hd, h),
                (h, inter), (h, inter), (inter, h)] * nl                  # q, k, v, o, gate, up, down
        bias = 0
        if cfg.get('attention_bias') or cfg.get('mlp_bias'):
            raise NotImplementedError('biases on llama/mistral linears')
        norms = 2 * h * nl + h                                            # 2 RMSNorm per layer + final
        kv_dim = nkv * hd
        max_pos = cfg['max_position_embeddings']
    else:
        raise NotImplementedError(f'model_type {mt}')
    return dict(gemv=gemv, lm_head=v * h, embed_row=h, bias=bias, norms=norms,
                kv_per_ctx=2 * nl * kv_dim, max_pos=max_pos, n_layers=nl)


def regime_b(paths, ctxs, bws):
    print('REGIME B - analytic batch-1 decode model, NOT this system: compute is ASSUMED not to')
    print('limit; every weight byte is streamed from DRAM once per token. Bytes per token is the')
    print('primary result; tokens/s at the given bandwidths are ILLUSTRATIVE only.\n')
    for p in paths:
        cfg = json.load(open(p))
        sh = model_shapes(cfg)
        n_w = sum(k * n for k, n in sh['gemv'])
        n_a = sum(k for k, _ in sh['gemv'])
        bf16_other = 2 * (sh['lm_head'] + sh['embed_row'] + sh['bias'] + sh['norms'])
        name = cfg.get('_name_or_path') or p
        print(f'== {name}  ({p})')
        print(f'   quantised linear weights {n_w:,} elements; GEMV input elements per token {n_a:,} '
              f'(activation/weight = 1/{n_w / n_a:,.0f}); BF16 lm_head+embedding row+biases+norms '
              f'{bf16_other:,} B/token; KV (BF16) {2 * sh["kv_per_ctx"]:,} B per token of context; '
              f'max context {sh["max_pos"]}')
        cols = [0] + [min(c, sh['max_pos']) for c in ctxs]
        for c_req, c in zip([0] + ctxs, cols):
            if c != c_req:
                print(f'   note: context {c_req} clamped to {c} (model maximum)')
        print(f'   {"format":24}{"b_w":>6}{"b_a":>6}' + ''.join(f'{"B/token L=" + str(c):>18}' for c in cols)
              + f'{"act share":>10}' + ''.join(f'{"vs MXFP8 L=" + str(c):>16}' for c in cols))
        rows = {}
        for fname, bw_, ba_, _ in FORMATS:
            w_b, a_b = n_w * bw_ / 8, n_a * ba_ / 8
            tot = [w_b + a_b + bf16_other + 2 * sh['kv_per_ctx'] * c for c in cols]
            rows[fname] = (tot, a_b / tot[0])
        for fname, bw_, ba_, _ in FORMATS:
            tot, share = rows[fname]
            ref = rows['MXFP8-E4M3'][0]
            print(f'   {fname:24}{bw_:6.2f}{ba_:6.2f}' + ''.join(f'{t:18,.0f}' for t in tot)
                  + f'{100 * share:9.3f}%' + ''.join(f'{r / t:16.3f}' for r, t in zip(ref, tot)))
        print(f'   illustrative tokens/s (bandwidth / bytes per token) at L={cols[0]} and L={cols[-1]}:')
        for fname, *_ in FORMATS:
            tot, _ = rows[fname]
            print(f'   {fname:24}' + ''.join(f'{b / 1e9:6.1f} GB/s: {b / tot[0]:8.2f} | {b / tot[-1]:8.2f} tok/s   '
                                         for b in bws))
        print()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('regime-a')
    a.add_argument('loops', nargs='+')
    b = sub.add_parser('regime-b')
    b.add_argument('configs', nargs='+')
    b.add_argument('--ctx', default='512,4096')
    b.add_argument('--bw', default='17e9,50e9')
    args = ap.parse_args()
    if args.cmd == 'regime-a':
        regime_a(args.loops)
    else:
        regime_b(args.configs, [int(x) for x in args.ctx.split(',')], [float(x) for x in args.bw.split(',')])


if __name__ == '__main__':
    sys.exit(main())
