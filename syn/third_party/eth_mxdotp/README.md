# ETH MXDOTP (third-party baseline, unchanged)

Used only as a synthesis baseline (`syn/wrappers/mx_syn_eth.sv`, `mx_syn_eth8.sv`;
filelists `syn/filelists/eth.f`, `eth8.f`). Never part of any simulation build.

- Origin: ETH Zurich / University of Bologna MXDOTP (package author Gamze Islamoglu),
  Solderpad Hardware License 0.51 (file headers). `mxdotp_multi_wrapper.sv` is ETH's
  standalone wrapper from their repository (confirmed by the collaborator, 9 Nov 2026).
- Received as `zurich_mxdotp.zip`, sha256
  `73f561f3dc7bf2089b285691a41fa43ba982ff0cdfc86a2ebcde5a9e105a7a83`; files unzipped
  unchanged. Upstream repository URL and commit: [DATA: not recorded].
- Pipeline as shipped: `NumPipeRegs = 3`, `PipeConfig = DISTRIBUTED`, i.e. one register
  stage each before, inside and after the datapath (`NUM_INP_REGS = (3+1)/3 = 1`,
  `NUM_MID_REGS = (3+2)/3 = 1`, `NUM_OUT_REGS = 3/3 = 1`).

| file | sha256 |
|---|---|
| cf_math_pkg.sv | afc32fcae21f6cbb834c5ee602a1aaee1b518fc436a86d4fe1b97942473d35c8 |
| fpnew_classifier.sv | f60c930f3d306b3b22507e24cf3c78ffbc40ab02623b1226c92a136dc365734b |
| fpnew_mxdotp_multi_modules.sv | 0711d2361c6d6429cbb292326635247fdc53d1cce652f80c016618428f4bd147 |
| fpnew_mxdotp_multi_pkg.sv | 0ae60958293553a4e341c03a6f6bbfc01ff0f7efd0dbe237da7899bf5a42fd11 |
| fpnew_pkg.sv | 5ef85da2bc43b585df6ee8b0954f563183eaf4bcf9ce8020204f4fdee57b302d |
| fpnew_rounding.sv | b7ca1dcbe08ccd4eb0da15c4d514f1c23cc35be98d0363e832d518ebf4b3c543 |
| lzc.sv | c47046cab67cd9e9ff46f9b2a4c055f301eabd0f135d76d96639eb41c9fa3609 |
| mxdotp_multi_wrapper.sv | 83dec1860e826e241a3e76d948d4b594961574a8cba20bc15de52101c3f36c45 |
| registers.sv | 532dfd1723d2936421b921235abdafcc8ca407990224992ca13575fdb620053a |
