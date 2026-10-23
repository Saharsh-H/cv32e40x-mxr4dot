# Running the Cadence flow on the GPU PC

The GPU PC has the Cadence tools but no git. The repo goes there as a tarball of
one **committed** tree, so every result can be traced back to a commit.
Don't edit files on the GPU PC. If something needs a fix, make it in WSL,
commit it, and copy a new tarball.

## 1. In WSL: make the two tarballs

```bash
cd ~/projects/cores/cv32e40x-mxdotp
git status --short                 # must print nothing: the tarball holds HEAD only
tb/scripts/fwdref_check.sh         # must exit 0 (Verilator is not on the GPU PC)
c=$(git rev-parse --short HEAD)
git archive --format=tar.gz --prefix=cv32e40x-mxdotp/ \
    --add-virtual-file=cv32e40x-mxdotp/MX_COMMIT:$(git rev-parse HEAD) \
    -o /mnt/c/Users/sahar/mxr4dot_syn_$c.tar.gz HEAD
# Library: the collaborator's copy (only lib/ and lef/ are used).
tar -czf /mnt/c/Users/sahar/nangate45_lib.tar.gz \
    -C ~/projects/cores/cadence_ref/srip_mxfp library/lib library/lef
```

`MX_COMMIT` holds the full commit hash. On the GPU PC, `run.sh` writes it into
every `run_info.txt` as `repo commit <hash> (tarball)`, together with the
sha256 of each library file it read.

Copy both files to the GPU PC with AnyDesk's file transfer.

## 2. On the GPU PC: set up (csh)

```csh
csh
source ~/cshrc_new
which genus innovus                # both must be found
mkdir -p $HOME/mx_syn
cd $HOME/mx_syn
tar -xzf mxr4dot_syn_<commit>.tar.gz
tar -xzf nangate45_lib.tar.gz
setenv MX_NANGATE_DIR $HOME/mx_syn/library
cd cv32e40x-mxdotp
cat MX_COMMIT
```

`run.sh` and `sweep.sh` are bash scripts. You can start them from csh as shown;
they inherit `PATH` and `MX_NANGATE_DIR`. After any command, `echo $status`
prints its exit code (0 = success).

If the tools need a different command line, set it before running:
`setenv GENUS_CMD "genus -batch -files"` and `setenv INNOVUS_CMD "innovus -batch -files"`
(these are the defaults).

## 3. First session: in this order, and nothing else

Stop at the first step that fails, and bring back what it produced (step 4).

**Step 1: smoke test.** Can the tools be started this way?

```csh
syn/cadence/run.sh smoke
```

Expected: two `PASS (exit 0)` lines, one per tool, each with a version. On a
FAIL, the output is in `syn/results/smoke/{genus,innovus}_smoke.out`.

**Step 2: fp4 synthesis at its start period (2.50 ns).**

```csh
syn/cadence/run.sh fp4 2.50 syn
```

Look at these under `syn/results/fp4/p2.500/genus/`:
- `genus.log`: any `Error` lines, especially at the commands marked
  UNVERIFIED in `genus.tcl`.
- `reports/mx_summary.txt`: is `setup_wns_raw` a number?
- Does that number equal the slack in `reports/timing_top.rpt`, and is it in ps?
  (`sweep.sh` assumes ps.)
- `reports/check_design_elab.rpt` and `check_unresolved_elab.rpt`: unresolved
  references or undriven nets.

**Step 3: fp4 place and route at the same period.**

```csh
syn/cadence/run.sh fp4 2.50 pnr
```

Look at these under `syn/results/fp4/p2.500/innovus/`:
- `innovus.log`:
  - any `MX_STOP` line (redefined cell, pin mismatch, rejected `-usefulSkew`);
  - the `MX_SKEW` line (which useful-skew switches were accepted);
  - any message about useful skew during `clock_opt_design`;
  - `Error` lines.
- `reports/pins.rpt`: are all pins placed?
- `reports/mx_summary.txt`: setup and hold WNS, and pin counts. Do they match
  `reports/timeDesign_setup` and `timeDesign_hold`?

No sweep in this session. `sweep.sh` comes after these three steps have been
checked.

## 4. Bring back

```csh
cd $HOME/mx_syn/cv32e40x-mxdotp
tar -czf $HOME/mx_syn/first_session.tar.gz syn/results/smoke syn/results/fp4
```

Copy `first_session.tar.gz` back to Windows. Claude reads it from WSL (logs,
reports, summaries) and fixes the UNVERIFIED commands before any further run.
