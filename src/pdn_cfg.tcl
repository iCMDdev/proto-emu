#
# PDN for tt_um_example
#
# SRAM:
#   location    = [20, 20]
#   orientation = R180
#
# Normal core PDN remains on Metal4.
# Three horizontal TopMetal1 buses connect the SRAM:
#
#   VDD!       -> VPWR
#   VSS!       -> VGND
#   VDDARRAY!  -> VPWR
#

source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections


# ----------------------------------------------------------------------
# Explicit SRAM power connections
# ----------------------------------------------------------------------

add_global_connection \
    -net $::env(VDD_NET) \
    -inst_pattern {^sram$} \
    -pin_pattern {^VDD!$} \
    -power

add_global_connection \
    -net $::env(VDD_NET) \
    -inst_pattern {^sram$} \
    -pin_pattern {^VDDARRAY!$} \
    -power

add_global_connection \
    -net $::env(GND_NET) \
    -inst_pattern {^sram$} \
    -pin_pattern {^VSS!$} \
    -ground

global_connect


# ----------------------------------------------------------------------
# Voltage domain
# ----------------------------------------------------------------------

set secondary {}

foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if {$vdd != $::env(VDD_NET)} {
        lappend secondary $vdd
    }

    if {$gnd != $::env(GND_NET)} {
        lappend secondary $gnd
    }
}

set_voltage_domain \
    -name CORE \
    -power $::env(VDD_NET) \
    -ground $::env(GND_NET) \
    -secondary_power $secondary


# ----------------------------------------------------------------------
# Normal core PDN
# ----------------------------------------------------------------------

define_pdn_grid \
    -name stdcell_grid \
    -starts_with POWER \
    -voltage_domains {CORE} \
    -pins $::env(PDN_VERTICAL_LAYER)


# Normal repeating vertical Metal4 grid.
# Uses FP_PDN_VPITCH / VWIDTH / VSPACING / VOFFSET from config.json.
add_pdn_stripe \
    -grid stdcell_grid \
    -layer $::env(PDN_VERTICAL_LAYER) \
    -width $::env(PDN_VWIDTH) \
    -pitch $::env(PDN_VPITCH) \
    -offset $::env(PDN_VOFFSET) \
    -spacing $::env(PDN_VSPACING) \
    -starts_with POWER


# ----------------------------------------------------------------------
# Locate SRAM
# ----------------------------------------------------------------------

set block [ord::get_db_block]
set sram [$block findInst sram]

if {$sram == "NULL"} {
    utl::error PDN 900 "SRAM instance 'sram' not found."
}

set sram_bbox [$sram getBBox]
set core_bbox [$block getCoreArea]

set sram_xmin [ord::dbu_to_microns [$sram_bbox xMin]]
set sram_ymin [ord::dbu_to_microns [$sram_bbox yMin]]
set sram_ymax [ord::dbu_to_microns [$sram_bbox yMax]]

set core_ymin [ord::dbu_to_microns [$core_bbox yMin]]

set sram_height [expr {$sram_ymax - $sram_ymin}]

puts "SRAM xmin   = $sram_xmin"
puts "SRAM ymin   = $sram_ymin"
puts "SRAM ymax   = $sram_ymax"
puts "SRAM height = $sram_height"


# ----------------------------------------------------------------------
# SRAM TopMetal1 buses
# ----------------------------------------------------------------------
#
# R0 pin regions:
#
#   VDD!       : y =   0.000 .. 47.045
#   VDDARRAY!  : y =  53.410 .. 219.770
#   VSS!       : spans SRAM height
#
# Original convenient R0 crossing positions:
#
#   VDD!       = 20
#   VSS!       = 50
#   VDDARRAY!  = 100
#
# SRAM is R180, therefore:
#
#   y_rotated = SRAM_HEIGHT - y_original
#
# giving approximately:
#
#   VDD!       = 199.770
#   VSS!       = 169.770
#   VDDARRAY!  = 119.770
#
# With SRAM ymin = 20:
#
#   VDD!       global y ~= 219.770
#   VSS!       global y ~= 189.770
#   VDDARRAY!  global y ~= 139.770
#

set vdd_r0_y      20.0
set vss_r0_y      50.0
set vddarray_r0_y 100.0

set vdd_local_y \
    [expr {$sram_height - $vdd_r0_y}]

set vss_local_y \
    [expr {$sram_height - $vss_r0_y}]

set vddarray_local_y \
    [expr {$sram_height - $vddarray_r0_y}]


set vdd_global_y \
    [expr {$sram_ymin + $vdd_local_y}]

set vss_global_y \
    [expr {$sram_ymin + $vss_local_y}]

set vddarray_global_y \
    [expr {$sram_ymin + $vddarray_local_y}]


# add_pdn_stripe offset is relative to core bottom.
set vdd_offset \
    [expr {$vdd_global_y - $core_ymin}]

set vss_offset \
    [expr {$vss_global_y - $core_ymin}]

set vddarray_offset \
    [expr {$vddarray_global_y - $core_ymin}]


set sram_bus_layer TopMetal1
set sram_bus_width 2.0

if {[info exists ::env(PDN_HORIZONTAL_LAYER)]} {
    set sram_bus_layer $::env(PDN_HORIZONTAL_LAYER)
}

if {[info exists ::env(PDN_HWIDTH)]} {
    set sram_bus_width $::env(PDN_HWIDTH)
}


puts "SRAM TopMetal1 buses:"
puts "  VDD!       y = $vdd_global_y"
puts "  VSS!       y = $vss_global_y"
puts "  VDDARRAY!  y = $vddarray_global_y"


# VDD! bus
add_pdn_stripe \
    -grid stdcell_grid \
    -layer $sram_bus_layer \
    -width $sram_bus_width \
    -pitch 10000 \
    -offset $vdd_offset \
    -nets [list $::env(VDD_NET)] \
    -extend_to_boundary


# VSS! bus
add_pdn_stripe \
    -grid stdcell_grid \
    -layer $sram_bus_layer \
    -width $sram_bus_width \
    -pitch 10000 \
    -offset $vss_offset \
    -nets [list $::env(GND_NET)] \
    -extend_to_boundary


# VDDARRAY! bus
add_pdn_stripe \
    -grid stdcell_grid \
    -layer $sram_bus_layer \
    -width $sram_bus_width \
    -pitch 10000 \
    -offset $vddarray_offset \
    -nets [list $::env(VDD_NET)] \
    -extend_to_boundary


# Connect normal Metal4 PDN to TopMetal1 buses.
add_pdn_connect \
    -grid stdcell_grid \
    -layers [list \
        $::env(PDN_VERTICAL_LAYER) \
        $sram_bus_layer \
    ]


# ----------------------------------------------------------------------
# SRAM macro grid
# ----------------------------------------------------------------------

define_pdn_grid \
    -macro \
    -name sram_grid \
    -instances {sram} \
    -voltage_domains {CORE} \
    -grid_over_pg_pins \
    -starts_with POWER


# Connect SRAM Metal4 PG pins to TopMetal1.
add_pdn_connect \
    -grid sram_grid \
    -layers [list \
        $::env(PDN_VERTICAL_LAYER) \
        $sram_bus_layer \
    ]


# ----------------------------------------------------------------------
# Standard-cell rails
# ----------------------------------------------------------------------

if {$::env(PDN_ENABLE_RAILS) == 1} {

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins

    add_pdn_connect \
        -grid stdcell_grid \
        -layers [list \
            $::env(PDN_RAIL_LAYER) \
            $::env(PDN_VERTICAL_LAYER) \
        ]
}