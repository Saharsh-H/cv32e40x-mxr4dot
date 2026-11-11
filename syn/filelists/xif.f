# Source list: the whole coprocessor (mxdotp_xif, all engines) as one design (mx_syn_xif).
# Paths are relative to the repo root. Same order as MXDOTP_SRCS in tb/Makefile,
# without mxdotp_core_top.sv (no CV32E40X core), plus cv32e40x_pkg and if_xif.
rtl/include/cv32e40x_pkg.sv
rtl/if_xif.sv
rtl/mxdotp/mxdotp_pkg.sv
rtl/mxdotp/mx_find_lead.sv
rtl/mxdotp/mx_finalize.sv
rtl/mxdotp/mx_acc_slide.sv
rtl/mxdotp/mxdotp_decoder.sv
rtl/mxdotp/mxdotp_dotp_engine.sv
rtl/mxdotp/mxdotp_final_engine.sv
rtl/mxdotp/mxdotp_fp4_fused_engine.sv
rtl/mxdotp/mxdotp_fp8_fused_engine.sv
rtl/mxdotp/mxdotp_m2xfp4_fused_engine.sv
rtl/mxdotp/mxdotp_mailbox.sv
rtl/mxdotp/mxdotp_xif.sv
syn/wrappers/mx_syn_xif.sv
