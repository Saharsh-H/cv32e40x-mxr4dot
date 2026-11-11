# Source list: ETH MXDOTP baseline, configuration as shipped (mx_syn_eth).
# Paths are relative to the repo root. ETH sources unchanged (syn/third_party/eth_mxdotp/README.md).
# registers.sv is not listed: mxdotp_multi_wrapper.sv pulls it in with `include.
# Order: packages first, then leaf modules, then the unit, then the harness.
syn/third_party/eth_mxdotp/cf_math_pkg.sv
syn/third_party/eth_mxdotp/fpnew_pkg.sv
syn/third_party/eth_mxdotp/fpnew_mxdotp_multi_pkg.sv
syn/third_party/eth_mxdotp/lzc.sv
syn/third_party/eth_mxdotp/fpnew_classifier.sv
syn/third_party/eth_mxdotp/fpnew_rounding.sv
syn/third_party/eth_mxdotp/fpnew_mxdotp_multi_modules.sv
syn/third_party/eth_mxdotp/mxdotp_multi_wrapper.sv
syn/wrappers/mx_syn_eth.sv
