# Source list: standalone synthesis of the m2 engine.
# Paths are relative to the repo root. MX_RTL = rtl/mxdotp.
#
# Order matters: the package must be read before anything that imports it,
# and the shared blocks before the engine that instantiates them.
rtl/mxdotp/mxdotp_pkg.sv
rtl/mxdotp/mx_find_lead.sv
rtl/mxdotp/mx_finalize.sv
rtl/mxdotp/mx_acc_slide.sv
rtl/mxdotp/mxdotp_m2xfp4_fused_engine.sv
syn/wrappers/mx_syn_m2.sv
