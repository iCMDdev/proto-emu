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

# Generate the physical PDN as before, but do not promote every generated
# segment into a block pin: pdngen cuts stripes at the SRAM and may insert
# short edge-repair stripes. Both fail the Tiny Tapeout power-pin check.
# Export only clear, normal-grid candidate stripes outside the SRAM.
# The SRAM feeder shapes must NOT be promoted to full-height external pins.
define_pdn_grid -name stdcell_grid \
    -starts_with POWER -voltage_domains {CORE}

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
# Only normal-grid straps wholly outside the SRAM can be continuous across
# the complete core height. Export those as module pins; not the clipped
# macro-aligned feeders or pdngen's channel-repair stubs.
set export_power {}
set export_ground {}

# Include strap half-width and a 1um macro clearance in the X test.
# A center outside the macro is NOT enough to guarantee unobstructed metal.
set pin_clearance 1.0
proc outside_sram_with_clearance {x width sx0 sx1 clearance} {
    set xl [expr {$x - $width / 2.0}]
    set xr [expr {$x + $width / 2.0}]
    return [expr {$xr + $clearance <= $sx0 || $xl - $clearance >= $sx1}]
}

# Calculate the coordinate of the first normal (i.e. non-SRAM) stripes
set px [expr {$cx0 + $::env(PDN_VOFFSET)}]
set gx [expr {$px + $::env(PDN_VWIDTH) + $::env(PDN_VSPACING)}]
for {set n 0} {1} {incr n} {
    # Calculate current iteration's stripe pair coords
    set p [expr {$px + $n*$::env(PDN_VPITCH)}]
    set g [expr {$gx + $n*$::env(PDN_VPITCH)}]

    # break if we're outside the core already
    if {$p > $cx1 && $g > $cx1} break

    # Do not place a strap if its metal rectangle would overhang the core
    # or interfere with the SRAM macro (including macro-edge clearance).
    if {$p - $NORMAL / 2.0 >= $cx0 && $p + $NORMAL / 2.0 <= $cx1 &&
        [outside_sram_with_clearance $p $NORMAL $sx0 $sx1 $pin_clearance]} {
        m4stripe $::env(VDD_NET) $NORMAL $p $cx0
        lappend export_power [list $p $NORMAL]
    }
    if {$g - $NORMAL / 2.0 >= $cx0 && $g + $NORMAL / 2.0 <= $cx1 &&
        [outside_sram_with_clearance $g $NORMAL $sx0 $sx1 $pin_clearance]} {
        m4stripe $::env(GND_NET) $NORMAL $g $cx0
        lappend export_ground [list $g $NORMAL]
    }
}

# SRAM-aligned M4 feeders
foreach x $wide_p { m4stripe $::env(VDD_NET) $WIDE $x $cx0 }
foreach x $wide_g { m4stripe $::env(GND_NET) $WIDE $x $cx0 }
foreach x $narrow_p { m4stripe $::env(VDD_NET) $NARROW $x $cx0 }
foreach x $narrow_g { m4stripe $::env(GND_NET) $NARROW $x $cx0 }

# Connect cells to PDN if needed (i.e. vias)
if {$::env(PDN_ENABLE_RAILS) == 1} {
    add_pdn_connect -grid stdcell_grid \
        -layers [list $::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)]
}


# The previous, KLayout-DRC-clean revision used short edge bridges to
# connect macro PG pins to the pdngen-generated SRAM-aligned feeders.
# These small rectangles touch the macro edges only; they do not cut across
# SRAM internal Metal4 obstructions.
set tech [ord::get_db_tech]
set m4 [$tech findLayer $::env(PDN_VERTICAL_LAYER)]
set vpwr [$block findNet $::env(VDD_NET)]
set vgnd [$block findNet $::env(GND_NET)]
if {$m4 == "NULL" || $vpwr == "NULL" || $vgnd == "NULL"} {
    utl::error PDN 901 "Cannot find vertical PDN layer or power nets."
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

# Pin rectangles are NOT additional metal: they must map to continuous
# physical M4 stripes generated by pdngen outside the macro X region.
set cy0 [ord::dbu_to_microns [$cb yMin]]
set cy1 [ord::dbu_to_microns [$cb yMax]]
set die [$block getDieArea]
set dy0 [ord::dbu_to_microns [$die yMin]]
set dy1 [ord::dbu_to_microns [$die yMax]]
if {$cy0 - $dy0 > 10.0 || $dy1 - $cy1 > 10.0} {
    utl::error PDN 904 "Core Y bounds are more than 10um from die edge; cannot export legal TT power pins."
}
if {$NORMAL < 1.2} {
    utl::error PDN 905 "Vertical power pin width is below Tiny Tapeout's 1.2um minimum."
}
if {[llength $export_power] == 0 || [llength $export_ground] == 0} {
    utl::error PDN 906 "No clear full-height normal-grid power/ground stripes outside SRAM."
}

# A dbBTerm is a named module connection; each dbBPin is an actual rectangle
# in that connection's pin definition. FIRM makes it survive pdngen, which
# otherwise deletes non-fixed existing pin shapes. Do not create SWires here.
proc fixed_power_ports {block net name sigtype layer stripes y0 y1} {
    set bt [$block findBTerm $name]
    if {$bt == "NULL"} {
        set bt [odb::dbBTerm_create $net $name]
    } elseif {[$bt getNet] != $net} {
        utl::error PDN 902 "BTerm $name is attached to a different net."
    }
    $bt setIoType INOUT
    $bt setSigType $sigtype
    $bt setSpecial
    if {[llength [$bt getBPins]] != 0} {
        utl::error PDN 903 "BTerm $name already has pin boxes; refusing to duplicate."
    }
    foreach stripe $stripes {
        lassign $stripe x width
        set half [expr {$width / 2.0}]
        set xl [ord::microns_to_dbu [expr {$x - $half}]]
        set xr [ord::microns_to_dbu [expr {$x + $half}]]
        set yb [ord::microns_to_dbu $y0]
        set yt [ord::microns_to_dbu $y1]
        set bp [odb::dbBPin_create $bt]
        odb::dbBox_create $bp $layer $xl $yb $xr $yt
        $bp setPlacementStatus FIRM
    }
    puts "[llength $stripes] fixed Metal4 block-pin rectangles on $name"
}
fixed_power_ports $block $vpwr $::env(VDD_NET) POWER $m4 $export_power $cy0 $cy1
fixed_power_ports $block $vgnd $::env(GND_NET) GROUND $m4 $export_ground $cy0 $cy1
