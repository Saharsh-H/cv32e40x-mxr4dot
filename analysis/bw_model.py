"""Task 5: memory traffic of MX dot products - two separate regimes, never mixed.

REGIME A - this system, measured (CV32E40X + MX coprocessor, task-3 K=4096 loops)
  python3 analysis/bw_model.py regime-a [--md] <loop.json> [<loop.json> ...]
  (analysis/regime_a_runs.sh makes the JSONs and calls this.) Each <loop.json> comes
  from tb/scripts/loop_report.py --json-out ... --meta format=<mxfp4|mxfp8|mxfp4r>,
  mode=<ideal|dwait|dgnt>,n=<n>, from a make-loop run with +gcount (measured data-port
  grants per region). Settings: ideal; dwait n = "read latency n" (every data response,
  load or store, n cycles later); dgnt n = "one data access per n+1 cycles". Tables:
  R1 cycles, elements/cycle, slowdown vs ideal, MXFP4R/MXFP8 and MXFP4/MXFP8 elements/
     cycle ratios, with the limit of each ratio in each mode: read latency -> ratio of the
     measured per-step increments (cycles added per latency step); bandwidth (one access
     per n+1 cycles) -> port-bound limit = inverse ratio of the measured grants;
  R2 read-latency linearity: added cycles per latency step and per grant;
  R3 bandwidth mode: cycles vs the port bound grants x (n+1);
  R4 data-port utilisation from measured grants (static layout counts as cross-check).

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
L (clamped to the model's maximum position). KV size uses num_key_value_heads
(grouped-query attention). Each GEMV reads its own input vector (q, k, v and gate,
up are counted separately; GPT-2's c_attn is one fused GEMV). Per token the BF16
lm_head matrix is read once (tied or not) plus one embedding row (GPT-2: plus one
position-embedding row).
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
FMTS = ('mxfp4', 'mxfp8', 'mxfp4r')
VARIANTS = (('20', 'NACC=4'), ('10', 'NACC=1'))
CAVEAT = ('REGIME A - this system (CV32E40X + MX coprocessor), MEASURED (MARK cycles, +gcount grants). '
          'Instruction port ideal (as if cached); synthetic data; pre-quantised activations (runtime '
          'quantisation not counted); the data-port model is a fixed latency / fixed rate model '
          '(tb/mem_model.sv), not a memory hierarchy. Not regime B.')


def setting_name(mode, n):
    return {'ideal': 'ideal', 'dwait': f'read latency {n}', 'dgnt': f'1 access / {n + 1} cyc'}[mode]


def regime_a(paths, md):
    runs = {}
    for p in paths:
        r = json.load(open(p))
        mode, n = r.get('mode', 'ideal'), int(r.get('n', 0))
        if mode == 'ideal':
            n = 0
        runs[(r['format'], mode, n)] = r
    settings = sorted({(m, n) for (_, m, n) in runs}, key=lambda x: ({'ideal': 0, 'dwait': 1, 'dgnt': 2}[x[0]], x[1]))
    fmts = [f for f in FMTS if any(k[0] == f for k in runs)]
    k = next(iter(runs.values()))['k']

    def reg(f, s, rid):
        return runs[(f, *s)]['regions'][rid]

    def table(title, head, rows):
        if md:
            print(f'\n**{title}**\n')
            print('| ' + ' | '.join(head) + ' |')
            print('|' + '---|' * len(head))
            for row in rows:
                print('| ' + ' | '.join(str(x) for x in row) + ' |')
        else:
            print(f'\n{title}')
            w = [max(len(str(x)) for x in col) for col in zip(head, *rows)]
            for row in [head] + rows:
                print('  '.join(str(x).rjust(c) for x, c in zip(row, w)))

    print(CAVEAT)
    # grants must not depend on timing: check, per format and variant, across settings
    for f in fmts:
        for rid, _ in VARIANTS:
            g = {reg(f, s, rid)['grants'] for s in settings if (f, *s) in runs}
            if len(g) != 1:
                print(f'WARNING: {f} region {rid} grants differ across settings: {sorted(g)}')
    for rid, var in VARIANTS:
        g = {f: reg(f, ('ideal', 0), rid)['grants'] for f in fmts}
        # R1
        head = ['setting'] + [f'{f} {c}' for f in fmts for c in ('cycles', 'elem/cyc', 'slowdown')]
        pairs = [(a, 'mxfp8') for a in ('mxfp4r', 'mxfp4') if a in fmts and 'mxfp8' in fmts]
        head += [f'{a}/{b}' for a, b in pairs]
        rows = []
        for s in settings:
            row = [setting_name(*s)]
            for f in fmts:
                c, c0 = reg(f, s, rid)['cycles'], reg(f, ('ideal', 0), rid)['cycles']
                row += [c, f'{k / c:.3f}', f'{c / c0:.3f}']
            row += [f'{reg(b, s, rid)["cycles"] / reg(a, s, rid)["cycles"]:.3f}' for a, b in pairs]
            rows.append(row)
        lat = sorted(n for (m, n) in settings if m == 'dwait')
        if lat:
            inc = {f: reg(f, ('dwait', lat[0]), rid)['cycles'] - reg(f, ('ideal', 0), rid)['cycles'] for f in fmts}
            rows.append(['read-latency limit (per-step increments)'] + [''] * (3 * len(fmts))
                        + [f'{inc[b] / inc[a]:.3f} ({inc[b]}/{inc[a]} cyc)' for a, b in pairs])
        rows.append(['bandwidth limit (port-bound, grants)'] + [''] * (3 * len(fmts))
                    + [f'{g[b] / g[a]:.3f} ({g[a]}/{g[b]} acc)' for a, b in pairs])
        table(f'R1 {var}: cycles, elements/cycle (K={k}), slowdown vs ideal, elements/cycle ratios. '
              f'Last two rows: the limit each ratio approaches as the latency grows (ratio of the cycles '
              f'added per latency step) and as the access rate falls (port-bound: inverse grant ratio)', head, rows)
        # R2
        rows = []
        for f in fmts:
            lat = sorted(n for (m, n) in settings if m == 'dwait')
            cyc = [reg(f, ('ideal', 0), rid)['cycles']] + [reg(f, ('dwait', n), rid)['cycles'] for n in lat]
            steps = [b - a for a, b in zip(cyc, cyc[1:])]
            const = len(set(steps)) == 1 and lat == list(range(1, len(lat) + 1))
            rows.append([f, ', '.join(map(str, steps)), 'yes' if const else 'NO', g[f],
                         f'{steps[0] / g[f]:.4f}' if steps else '', f'{g[f] / 2:g}'])
        table(f'R2 {var}: read latency, added cycles per step 0->1->...->5', 
              ['format', 'added cycles per step', 'constant', 'grants', 'per step / grants', 'grants / 2'], rows)
        # R3
        rows = []
        for f in fmts:
            for (m, n) in settings:
                if m != 'dgnt':
                    continue
                c = reg(f, (m, n), rid)['cycles']
                bound = g[f] * (n + 1)
                rows.append([f, setting_name(m, n), c, bound, f'{c / bound:.3f}'])
        table(f'R3 {var}: bandwidth mode, cycles vs port bound = grants x (n+1)',
              ['format', 'setting', 'cycles', 'bound', 'cycles / bound'], rows)
        # R4
        rows = []
        for f in fmts:
            wb, ab, acc = loop_traffic(f, k)
            for s in settings:
                c = reg(f, s, rid)['cycles']
                rows.append([f, setting_name(*s), c, g[f], f'{100 * g[f] / c / PORT_ACCESSES:.1f}%',
                             f'{(wb + ab) / c:.3f}', f'{100 * (wb + ab) / c / PORT_BYTES:.1f}%', acc])
        table(f'R4 {var}: data-port utilisation (measured grants; bytes from the data layout)',
              ['format', 'setting', 'cycles', 'grants', 'access slots used', 'data B/cyc', '% of 4 B/cyc',
               'static loop accesses'], rows)


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
        nkv, hd = nh, h // nh
        pos_emb = max_pos * h                                              # wpe (learned positions)
        window = None
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
        pos_emb = 0                                                        # rotary: no parameters
        window = cfg.get('sliding_window')
    else:
        raise NotImplementedError(f'model_type {mt}')
    # HF default for tie_word_embeddings is True (GPT-2's config does not set it)
    tied = cfg.get('tie_word_embeddings', True)
    return dict(gemv=gemv, lm_head=v * h, embed_row=h + (h if pos_emb else 0), bias=bias, norms=norms,
                kv_per_ctx=2 * nl * kv_dim, max_pos=max_pos, n_layers=nl, tied=tied, nkv=nkv, nh=nh,
                head_dim=hd, window=window,
                params=sum(k * n for k, n in gemv) + bias + norms + v * h + (0 if tied else v * h) + pos_emb)


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
        print(f'   parameters computed from config: {sh["params"]:,}; lm_head tied to the embedding: '
              f'{sh["tied"]} (lm_head matrix counted once per token, plus one embedding row'
              f'{" + one position row" if cfg.get("model_type") == "gpt2" else ""} read per token)')
        print(f'   attention heads {sh["nh"]}, KV heads {sh["nkv"]}, head_dim {sh["head_dim"]}'
              + (f', sliding window {sh["window"]}' if sh['window'] else ''))
        print(f'   quantised linear weights {n_w:,} elements; GEMV input elements per token {n_a:,} '
              f'(activation/weight = 1/{n_w / n_a:,.0f}); BF16 lm_head+embedding row(s)+biases+norms '
              f'{bf16_other:,} B/token; KV (BF16) {2 * sh["kv_per_ctx"]:,} B per token of context; '
              f'max context {sh["max_pos"]}')
        cols = [0] + [min(c, sh['max_pos']) for c in ctxs]
        if sh['window'] and any(c > sh['window'] for c in cols):
            raise NotImplementedError('context beyond the sliding window: KV read would be capped')
        for c_req, c in zip([0] + ctxs, cols):
            if c != c_req:
                print(f'   note: context {c_req} clamped to {c} (model maximum)')
        print(f'   {"format":24}{"b_w":>6}{"b_a":>6}' + ''.join(f'{"B/token L=" + str(c):>18}' for c in cols)
              + f'{"act B/tok":>11}{"act share":>10}' + ''.join(f'{"vs MXFP8 L=" + str(c):>16}' for c in cols))
        rows = {}
        for fname, bw_, ba_, _ in FORMATS:
            w_b, a_b = n_w * bw_ / 8, n_a * ba_ / 8
            tot = [w_b + a_b + bf16_other + 2 * sh['kv_per_ctx'] * c for c in cols]
            rows[fname] = (tot, a_b / tot[0], a_b)
        for fname, bw_, ba_, _ in FORMATS:
            tot, share, a_b = rows[fname]
            ref = rows['MXFP8-E4M3'][0]
            print(f'   {fname:24}{bw_:6.2f}{ba_:6.2f}' + ''.join(f'{t:18,.0f}' for t in tot)
                  + f'{a_b:11,.0f}{100 * share:9.3f}%' + ''.join(f'{r / t:16.3f}' for r, t in zip(ref, tot)))
        print(f'   illustrative tokens/s (bandwidth / bytes per token) at L={cols[0]} and L={cols[-1]}:')
        for fname, *_ in FORMATS:
            tot = rows[fname][0]
            print(f'   {fname:24}' + ''.join(f'{b / 1e9:6.1f} GB/s: {b / tot[0]:8.2f} | {b / tot[-1]:8.2f} tok/s   '
                                         for b in bws))
        print()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('regime-a')
    a.add_argument('loops', nargs='+')
    a.add_argument('--md', action='store_true', help='Markdown tables')
    b = sub.add_parser('regime-b')
    b.add_argument('configs', nargs='+')
    b.add_argument('--ctx', default='512,4096')
    b.add_argument('--bw', default='17e9,50e9')
    args = ap.parse_args()
    if args.cmd == 'regime-a':
        regime_a(args.loops, args.md)
    else:
        regime_b(args.configs, [int(x) for x in args.ctx.split(',')], [float(x) for x in args.bw.split(',')])


if __name__ == '__main__':
    sys.exit(main())
