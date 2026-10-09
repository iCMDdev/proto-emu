# Power Delivery Network configuration.
# Builds the normal Tiny Tapeout grid, but for the SRAM, it
# replaces the stripes with special ones, aligned with the 
# SRAM's Vdd/Vddarray/Vss power pins.

# Load normal OpenROAD config and set the usual global power connections
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

# Tell OpenROAD what the SRAM pins are connected to (Vdd & Vddarray = power; Vss=ground)
add_global_connection -net $::env(VDD_NET) -inst_pattern {^sram$} -pin_pattern {^VDD!$}      -power
add_global_connection -net $::env(VDD_NET) -inst_pattern {^sram$} -pin_pattern {^VDDARRAY!$} -power
add_global_connection -net $::env(GND_NET) -inst_pattern {^sram$} -pin_pattern {^VSS!$}      -ground
global_connect

# find extra supply nets that aren't VPWR / VGND
set secondary {}
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if {$vdd != $::env(VDD_NET)} { lappend secondary $vdd }
    if {$gnd != $::env(GND_NET)} { lappend secondary $gnd }
}

# Set the core's voltage domain
set_voltage_domain -name CORE \
    -power $::env(VDD_NET) -ground $::env(GND_NET) \
    -secondary_power $secondary

# Find SRAM instance
set block [ord::get_db_block]
set sram [$block findInst sram]
if {$sram == "NULL"} { utl::error PDN 900 "Instance sram not found." }

# Get SRAM and core bounding boxes / areas
set sb [$sram getBBox]
set cb [$block getCoreArea]
set sx0 [ord::dbu_to_microns [$sb xMin]]
set sy0 [ord::dbu_to_microns [$sb yMin]]
set sx1 [ord::dbu_to_microns [$sb xMax]]
set sy1 [ord::dbu_to_microns [$sb yMax]]
set cx0 [ord::dbu_to_microns [$cb xMin]]
set cx1 [ord::dbu_to_microns [$cb xMax]]

puts "SRAM bbox = {$sx0 $sy0 $sx1 $sy1}, orient=[$sram getOrient]"

# Add SRAM power connections.
# Symmetric distributed subset of exact SRAM PG centers after R180.
# The right-side selections are exact mirrors of the left-side selections
# about the SRAM center x = 221.305um.
set wide_p  {28.355 63.715 99.075 134.435 308.175 343.535 378.895 414.255}
set wide_g  {37.195 72.555 107.915 143.275 299.335 334.695 370.055 405.415}
set narrow_p {187.830 213.580 229.030 254.780}
set narrow_g {192.980 208.430 234.180 249.630}

# Port width: WIDE & NARROW are SRAM-specific, while NORMAL is the
# configured PDN_VWIDTH.
set WIDE   4.42
set NARROW 2.81
set NORMAL $::env(PDN_VWIDTH)

# Define the PDN grid
define_pdn_grid -name stdcell_grid \
    -starts_with POWER -voltage_domains {CORE} \
    -pins $::env(PDN_VERTICAL_LAYER)

# Add standard cell rails if enabled
if {$::env(PDN_ENABLE_RAILS) == 1} {
    add_pdn_stripe -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) -followpins
}

# Add one full-height M4 stripe at an absolute X coordinate.
proc m4stripe {net width x core_xmin} {
    add_pdn_stripe -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -nets [list $net] \
        -width $width \
        -pitch $::env(PDN_VPITCH) \
        -offset [expr {$x - $core_xmin}] \
        -number_of_straps 1
}

# Preserve the normal 2.1um/50um grid outside the SRAM X-span.
# The SRAM X-span is intentionally replaced by aligned feeder stripes.

# Calculate the coordinate of the first normal (i.e. non-SRAM) stripes
set px [expr {$cx0 + $::env(PDN_VOFFSET)}]
set gx [expr {$px + $::env(PDN_VWIDTH) + $::env(PDN_VSPACING)}]
for {set n 0} {1} {incr n} {
    # Calculate current iteration's stripe pair coords
    set p [expr {$px + $n*$::env(PDN_VPITCH)}]
    set g [expr {$gx + $n*$::env(PDN_VPITCH)}]

    # break if we're outside the core already
    if {$p > $cx1 && $g > $cx1} break

    # add each stripe if it is inside the SRAM & core
    if {$p <= $cx1 && ($p < $sx0 || $p > $sx1)} {
        m4stripe $::env(VDD_NET) $NORMAL $p $cx0
    }
    if {$g <= $cx1 && ($g < $sx0 || $g > $sx1)} {
        m4stripe $::env(GND_NET) $NORMAL $g $cx0
    }
}

# SRAM-aligned M4 feeders
foreach x $wide_p   { m4stripe $::env(VDD_NET) $WIDE   $x $cx0 }
foreach x $wide_g   { m4stripe $::env(GND_NET) $WIDE   $x $cx0 }
foreach x $narrow_p { m4stripe $::env(VDD_NET) $NARROW $x $cx0 }
foreach x $narrow_g { m4stripe $::env(GND_NET) $NARROW $x $cx0 }

# Connect cells to PDN if needed (i.e. vias)
if {$::env(PDN_ENABLE_RAILS) == 1} {
    add_pdn_connect -grid stdcell_grid \
        -layers [list $::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)]
}


# Problem: PDNGen does not connect th PDN stripes to the macro - it
# clips those stripes, and a gap exists between the macro and those
# stripes. We need to add some bridges that fill that tiny gap with
# same-layer Metal4.

# Get Metal4 layer
set tech [ord::get_db_tech]
set m4 [$tech findLayer $::env(PDN_VERTICAL_LAYER)]

# Get the Vdd and GND nets
set vpwr [$block findNet $::env(VDD_NET)]
set vgnd [$block findNet $::env(GND_NET)]
if {$m4 == "NULL" || $vpwr == "NULL" || $vgnd == "NULL"} {
    utl::error PDN 901 "Could not find M4/VPWR/VGND for SRAM bridges."
}

$vpwr setSpecial
$vgnd setSpecial
set psw [odb::dbSWire_create $vpwr ROUTED]
set gsw [odb::dbSWire_create $vgnd ROUTED]

# helper to draw a Metal4 bridge
proc bridge {sw layer x width y0 y1} {
    set h [expr {$width/2.0}]
    odb::dbSBox_create $sw $layer \
        [ord::microns_to_dbu [expr {$x-$h}]] \
        [ord::microns_to_dbu $y0] \
        [ord::microns_to_dbu [expr {$x+$h}]] \
        [ord::microns_to_dbu $y1] STRIPE
}

# set the overlap to 1um
set ov 1.0
set top0 [expr {$sy1-$ov}]
set top1 [expr {$sy1+$ov}]
set bot0 [expr {$sy0-$ov}]
set bot1 [expr {$sy0+$ov}]

# Actually add bridges using helper
# Wide VPWR: VDD! at top, VDDARRAY! at bottom.
foreach x $wide_p {
    bridge $psw $m4 $x $WIDE $top0 $top1
    bridge $psw $m4 $x $WIDE $bot0 $bot1
}

# Wide VSS!, narrow VDD!, and narrow VSS! reach both edges.
foreach x $wide_g {
    bridge $gsw $m4 $x $WIDE $top0 $top1
    bridge $gsw $m4 $x $WIDE $bot0 $bot1
}

# Narrow connections
foreach x $narrow_p {
    bridge $psw $m4 $x $NARROW $top0 $top1
    bridge $psw $m4 $x $NARROW $bot0 $bot1
}
foreach x $narrow_g {
    bridge $gsw $m4 $x $NARROW $top0 $top1
    bridge $gsw $m4 $x $NARROW $bot0 $bot1
}
