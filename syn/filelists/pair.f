# Source list: the MXFP4R residue pair as one design (mxresdot + mailbox + mxfinal).
# Paths are relative to the repo root.
#
# Order matters: the package must be read before anything that imports it,
# and the shared blocks before the engine that instantiates them.
rtl/mxdotp/mxdotp_pkg.sv
rtl/mxdotp/mx_find_lead.sv
rtl/mxdotp/mx_finalize.sv
rtl/mxdotp/mxdotp_dotp_engine.sv
rtl/mxdotp/mxdotp_mailbox.sv
rtl/mxdotp/mxdotp_final_engine.sv
syn/wrappers/mx_syn_pair.sv
