#
# Temporary CMOS5L SRAM PDN configuration.
#
# Keep the standard Tiny Tapeout single-layer Metal4 PDN, then add
# one VPWR and one VGND Metal4 stripe aligned with known power pin
# columns of RM_IHPSG13_2P_512x16_c2_bm_bist.
#
# This is intended as an initial hardening / connectivity test.
#

source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

#
# Explicitly connect the SRAM supply pins to the project supplies.
#
# PDN_CONNECT_MACROS_TO_GRID is disabled, so do not rely on the
# generic LibreLane macro-grid mechanism to do this for us.
#
add_global_connection \
    -net $::env(VDD_NET) \
    -inst_pattern {^sram$} \
    -pin_pattern {^VDD!$}

add_global_connection \
    -net $::env(VDD_NET) \
    -inst_pattern {^sram$} \
    -pin_pattern {^VDDARRAY!$}

add_global_connection \
    -net $::env(GND_NET) \
    -inst_pattern {^sram$} \
    -pin_pattern {^VSS!$}

global_connect


#
# Set up the core voltage domain.
#
set secondary []

foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET) } {
        lappend secondary $vdd
    }

    if { $gnd != $::env(GND_NET) } {
        lappend secondary $gnd
    }
}

set_voltage_domain \
    -name CORE \
    -power $::env(VDD_NET) \
    -ground $::env(GND_NET) \
    -secondary_power $secondary


#
# Standard Tiny Tapeout single-layer PDN.
#
# For CMOS5L this is the normal vertical Metal4 grid.
#
define_pdn_grid \
    -name stdcell_grid \
    -starts_with POWER \
    -voltage_domain CORE \
    -pins $::env(PDN_VERTICAL_LAYER)


#
# Normal repeating Tiny Tapeout VPWR/VGND stripes.
#
add_pdn_stripe \
    -grid stdcell_grid \
    -layer $::env(PDN_VERTICAL_LAYER) \
    -width $::env(PDN_VWIDTH) \
    -pitch $::env(PDN_VPITCH) \
    -offset $::env(PDN_VOFFSET) \
    -spacing $::env(PDN_VSPACING) \
    -starts_with POWER


#
# Find where the SRAM actually ended up.
#
set block [ord::get_db_block]
set sram [$block findInst sram]

if { $sram == "NULL" } {
    utl::error PDN 900 "SRAM instance 'sram' was not found."
}

set sram_bbox [$sram getBBox]
set core_bbox [$block getCoreArea]

set sram_x [ord::dbu_to_microns [$sram_bbox xMin]]
set core_x [ord::dbu_to_microns [$core_bbox xMin]]


#
# Power-pin centers from the SRAM LEF, for orientation R0:
#
# VDD!/VDDARRAY!:
#   RECT 6.145 ... 10.565
#   center = 8.355 um
#
# VSS!:
#   RECT 14.985 ... 19.405
#   center = 17.195 um
#
set sram_vpwr_x [expr {$sram_x + 8.355}]
set sram_vgnd_x [expr {$sram_x + 17.195}]

#
# add_pdn_stripe offsets are relative to the core lower-left corner.
#
set sram_vpwr_offset [expr {$sram_vpwr_x - $core_x}]
set sram_vgnd_offset [expr {$sram_vgnd_x - $core_x}]

puts "SRAM bbox x:             $sram_x"
puts "Core left x:             $core_x"
puts "SRAM VPWR stripe x:      $sram_vpwr_x"
puts "SRAM VGND stripe x:      $sram_vgnd_x"
puts "SRAM VPWR PDN offset:    $sram_vpwr_offset"
puts "SRAM VGND PDN offset:    $sram_vgnd_offset"


#
# Add one extra Metal4 VPWR stripe exactly over the SRAM's
# VDD!/VDDARRAY! column.
#
# Huge pitch ensures only one occurs in this design.
#
add_pdn_stripe \
    -grid stdcell_grid \
    -layer $::env(PDN_VERTICAL_LAYER) \
    -width $::env(PDN_VWIDTH) \
    -pitch 10000 \
    -offset $sram_vpwr_offset \
    -nets "$::env(VDD_NET)" \
    -extend_to_boundary


#
# Add one extra Metal4 VGND stripe exactly over the adjacent
# full-height VSS! column.
#
add_pdn_stripe \
    -grid stdcell_grid \
    -layer $::env(PDN_VERTICAL_LAYER) \
    -width $::env(PDN_VWIDTH) \
    -pitch 10000 \
    -offset $sram_vgnd_offset \
    -nets "$::env(GND_NET)" \
    -extend_to_boundary


#
# Standard-cell Metal1 rails.
#
if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)"
}