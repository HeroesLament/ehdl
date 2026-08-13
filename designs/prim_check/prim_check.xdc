# Build-check constraints. NOT FOR LOADING -- these pads are the AD9363 receive
# bus, driven here as outputs.
#
# ddr_p/ddr_n are V16/W16 = IO_L18P/N_T2_34, one differential pair in tile
# RIOB33_X73Y63: IOB_X1Y64 (P, IOB33M, FASM IOB_Y0) and IOB_X1Y63 (N, IOB33S).

set_property PACKAGE_PIN V16 [get_ports ddr_p]
set_property PACKAGE_PIN W16 [get_ports ddr_n]
set_property IOSTANDARD LVDS_25 [get_ports ddr_p]
set_property IOSTANDARD LVDS_25 [get_ports ddr_n]

set_property PACKAGE_PIN N20 [get_ports ref_clk]
set_property IOSTANDARD LVCMOS25 [get_ports ref_clk]

set_property PACKAGE_PIN R14 [get_ports clk_pad]
set_property IOSTANDARD LVCMOS25 [get_ports clk_pad]

set_property PACKAGE_PIN P15 [get_ports d_rise]
set_property PACKAGE_PIN R19 [get_ports d_fall]
set_property PACKAGE_PIN P18 [get_ports p_hi]
set_property PACKAGE_PIN N17 [get_ports pll_locked]
set_property IOSTANDARD LVCMOS25 [get_ports d_rise]
set_property IOSTANDARD LVCMOS25 [get_ports d_fall]
set_property IOSTANDARD LVCMOS25 [get_ports p_hi]
set_property IOSTANDARD LVCMOS25 [get_ports pll_locked]
