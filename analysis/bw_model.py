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


# eval v2 result layout (run_eval.py): <eval_dir>/language/<model_name with / -> __>/<mode>.json,
# key 'ppl' = WikiText-2 perplexity. Config file stem -> model folder; format -> eval quant_mode.
EVAL_MODEL_DIRS = {'gpt2': 'gpt2', 'llama2_7b': 'meta-llama__Llama-2-7b-hf',
                   'mistral_7b': 'mistralai__Mistral-7B-v0.1', 'llama3_8b': 'meta-llama__Meta-Llama-3-8B'}
EVAL_MODES = {'BF16': 'bf16', 'MXFP8-E4M3': 'mxfp8_e4m3', 'MXFP4': 'mxfp4', 'NVFP4': 'nvfp4',
              'M2XFP4': 'm2xfp', 'MXFP4R (residue A)': 'mxfp4_residual_act_only',
              'MXFP4R (residue W)': 'mxfp4_residual_weight_only', 'MXFP4R (residue both)': 'mxfp4_residual'}
# the MXFP4R variant eval v2 evaluates by default (frameworks/language.py "MXFP4R default",
# ci_report.py --ref) and the one the hardware implements; the other two are alternatives
MXFP4R_HEADLINE = 'MXFP4R (residue A)'


B_CAVEAT = ('Regime B: analytic batch-1 decode model, not this system. Compute is assumed not to limit; every '
            'weight byte is streamed from DRAM once per token; the KV cache is BF16 for every format; '
            'tokens/s are illustrative only. Not regime A.')


def print_table(title, head, rows, md):
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


def read_ci(paths):
    """ci_report.py Markdown (eval v2, unchanged script) -> {ref: {model_dir: {mode: (diff, ci, excl)}}}."""
    import re
    out = {}
    for p in paths or []:
        model = ref = None
        for line in open(p):
            m = re.match(r'### (\S+)', line)
            if m:
                model = m[1]
                continue
            m = re.match(r'\| mode \|.*\| diff vs (\S+) \|', line)
            if m:
                ref = m[1]
                continue
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            if model and ref and len(cells) == 6 and cells[0] not in ('mode', '---'):
                out.setdefault(ref, {}).setdefault(model, {})[cells[0]] = (cells[3], cells[4], cells[5], p)
    return out


def model_bytes(cfg, ctx_list):
    sh = model_shapes(cfg)
    n_w = sum(k * n for k, n in sh['gemv'])
    n_a = sum(k for k, _ in sh['gemv'])
    other = 2 * (sh['lm_head'] + sh['embed_row'] + sh['bias'] + sh['norms'])
    cols = [min(c, sh['max_pos']) for c in ctx_list]
    if sh['window'] and any(c > sh['window'] for c in cols):
        raise NotImplementedError('context beyond the sliding window: KV read would be capped')
    tot = {f: [n_w * bw_ / 8 + n_a * ba_ / 8 + other + 2 * sh['kv_per_ctx'] * c for c in cols]
           for f, bw_, ba_, _ in FORMATS}
    act = {f: n_a * ba_ / 8 for f, _, ba_, _ in FORMATS}
    return sh, n_w, n_a, other, cols, tot, act


def label(fname):
    return fname + (' (headline)' if fname == MXFP4R_HEADLINE else (' (alternative)' if fname.startswith('MXFP4R') else ''))


def regime_b(paths, ctxs, bws, md=False, eval_dir=None, acc_ctx=512, index_dir=None, ci_files=None):
    import os
    print(B_CAVEAT)
    ctx_list = [0] + ctxs
    ci = read_ci(ci_files)
    summary = []
    for p in paths:
        cfg = json.load(open(p))
        stem = os.path.splitext(os.path.basename(p))[0]
        sh, n_w, n_a, other, cols, tot, act = model_bytes(cfg, ctx_list)
        ref = tot['MXFP8-E4M3']
        clamp = [f'{c_req} clamped to {c}' for c_req, c in zip(ctx_list, cols) if c != c_req]
        print(f'\n### {stem}  ({p})\n' if md else f'\n== {stem}  ({p})')
        print(f'Parameters (from config) {sh["params"]:,}; lm_head tied to the embedding: {sh["tied"]}; '
              f'attention heads {sh["nh"]}, KV heads {sh["nkv"]}, head_dim {sh["head_dim"]}'
              + (f', sliding window {sh["window"]}' if sh['window'] else '')
              + f'; KV cache (BF16) {2 * sh["kv_per_ctx"]:,} B per token of context; max context {sh["max_pos"]}'
              + (f' ({"; ".join(clamp)})' if clamp else '') + '.')
        print(f'Per token: quantised linear weights {n_w:,} elements; GEMV input elements {n_a:,}; BF16 '
              f'lm_head + embedding row(s) + biases + norms {other:,} B (lm_head alone {2 * sh["lm_head"]:,} B).')
        head = ['format', 'b_w', 'b_a'] + [f'B/token L={c}' for c in cols] + ['act B/token', 'act share (L=0)'] \
            + [f'MXFP8 ÷ format L={c}' for c in cols]
        rows = [[label(f), f'{bw_:.2f}', f'{ba_:.2f}'] + [f'{t:,.0f}' for t in tot[f]]
                + [f'{act[f]:,.0f}', f'{100 * act[f] / tot[f][0]:.3f}%'] + [f'{r / t:.3f}' for r, t in zip(ref, tot[f])]
                for f, bw_, ba_, _ in FORMATS]
        print_table(f'B1 {stem}: bytes per token by context length L ({B_CAVEAT.split(".")[0]})', head, rows, md)
        head = ['format'] + [f'{b / 1e9:g} GB/s, L={c}' for b in bws for c in (cols[0], cols[-1])]
        rows = [[label(f)] + [f'{b / tot[f][i]:.2f}' for b in bws for i in (0, -1)] for f, *_ in FORMATS]
        print_table(f'B2 {stem}: ILLUSTRATIVE tokens/s = bandwidth / bytes per token (not a prediction)', head, rows, md)
        if eval_dir:
            c = min(acc_ctx, sh['max_pos'])
            i = cols.index(c) if c in cols else None
            t512 = {f: tot[f][i] for f in tot} if i is not None else model_bytes(cfg, [c])[5]
            t512 = {f: (v if not isinstance(v, list) else v[0]) for f, v in t512.items()}
            mdir = EVAL_MODEL_DIRS.get(stem)
            head = ['format', f'B/token L={c}', 'MXFP8 ÷ format', 'PPL', 'seq_len',
                    f'Δ PPL vs {EVAL_MODES[MXFP4R_HEADLINE]} [95% CI]', 'sig', 'Δ PPL vs mxfp8_e4m3 [95% CI]', 'sig',
                    'PPL source (path : key)']
            rows = []
            for f, *_ in FORMATS:
                mode = EVAL_MODES[f]
                fp = os.path.join(eval_dir, 'language', mdir, mode + '.json') if mdir else None
                if fp and os.path.exists(fp):
                    r = json.load(open(fp))
                    ppl, sl, src = f'{r["ppl"]:.4g}', r['seq_len'], f'`{fp}` : `ppl`'
                else:
                    ppl, sl, src = '[DATA: missing]', '', '[DATA: missing]'
                cells = []
                for rf in (EVAL_MODES[MXFP4R_HEADLINE], 'mxfp8_e4m3'):
                    e = ci.get(rf, {}).get(mdir, {}).get(mode)
                    cells += ([f'{e[0]} {e[1]}', e[2]] if e and e[0] != '—' else (['ref', ''] if e else ['[DATA: missing]', '']))
                rows.append([label(f), f'{t512[f]:,.0f}', f'{t512["MXFP8-E4M3"] / t512[f]:.3f}', ppl, sl] + cells + [src])
            print_table(f'B3 {stem}: bytes per token at L={c} paired with WikiText-2 perplexity (eval v2) and paired '
                        f'bootstrap CIs (eval v2 ci_report.py; Δ = mode − reference; sig = CI excludes 0)', head, rows, md)
            srcs = sorted({e[3] for rf in ci.values() for m in rf.values() for e in m.values()})
            if srcs:
                print('\nCI sources: ' + ', '.join(f'`{s}`' for s in srcs))
        r_a, mx4 = tot[MXFP4R_HEADLINE], tot['MXFP4']
        summary.append([stem, sh['nkv'], f'{2 * sh["kv_per_ctx"]:,}',
                        f'{100 * (r_a[1] - mx4[1]) / mx4[1]:.3f}%',
                        f'{100 * (tot["NVFP4"][1] - r_a[1]) / tot["NVFP4"][1]:.2f}%',
                        f'{100 * (tot["M2XFP4"][1] - r_a[1]) / tot["M2XFP4"][1]:.2f}%',
                        f'{100 * 2 * sh["lm_head"] / r_a[1]:.1f}%']
                       + [f'{ref[i] / r_a[i]:.3f} (L={cols[i]})' for i in range(len(cols))])
    print_table(f'B4 summary at L={ctx_list[1]} unless stated ({MXFP4R_HEADLINE} = MXFP4R)',
                ['model', 'KV heads', 'KV B per ctx token', 'MXFP4R − MXFP4 bytes', 'MXFP4R fewer bytes than NVFP4',
                 'than M2XFP4', 'BF16 lm_head share of MXFP4R bytes'] + ['MXFP8 ÷ MXFP4R, L=0'] + [f'MXFP8 ÷ MXFP4R, L={c} (or max)' for c in ctx_list[1:]],
                summary, md)
    if index_dir:
        rows = []
        for p in paths:
            stem = os.path.splitext(os.path.basename(p))[0]
            comp = model_shapes(json.load(open(p)))['params']
            f = os.path.join(index_dir, stem + '.index.json')
            if not os.path.exists(f):
                rows.append([stem, f'{comp:,}', '(no index file)', '', ''])
                continue
            d = json.load(open(f))
            n = d['metadata']['total_size'] // 2
            bufs = [k for k in d['weight_map'] if k.endswith('inv_freq')]
            rows.append([stem, f'{comp:,}', f'{n:,}', f'{n - comp:+,}',
                         f'{len(bufs)} rotary inv_freq buffers in the checkpoint' if bufs else ''])
        print_table('B5 parameter check: computed from config vs checkpoint index metadata.total_size / 2 '
                    '(2-byte parameters)', ['model', 'computed', 'index / 2', 'diff', 'note'], rows, md)


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
    b.add_argument('--eval-dir', help='eval v2 results (language/<model>/<mode>.json): pair PPL with bytes/token')
    b.add_argument('--acc-ctx', type=int, default=512, help='context length for the accuracy pairing')
    b.add_argument('--index-dir', help='checkpoint *.index.json files: parameter-count check')
    b.add_argument('--ci', nargs='*', help='ci_report.py Markdown outputs (paired bootstrap CIs) to join')
    b.add_argument('--md', action='store_true', help='Markdown tables')
    args = ap.parse_args()
    if args.cmd == 'regime-a':
        regime_a(args.loops, args.md)
    else:
        regime_b(args.configs, [int(x) for x in args.ctx.split(',')], [float(x) for x in args.bw.split(',')],
                 md=args.md, eval_dir=args.eval_dir, acc_ctx=args.acc_ctx, index_dir=args.index_dir, ci_files=args.ci)


if __name__ == '__main__':
    sys.exit(main())
