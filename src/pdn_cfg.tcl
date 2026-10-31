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
# Fixed, full-height block pins are created explicitly below.
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
# Remember intended normal stripes for export as block pins; this avoids
# accidentally exporting short PDN channel-repair stripes at the left edge.
set export_power {}
set export_ground {}

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
        lappend export_power [list $p $NORMAL]
    }
    if {$g <= $cx1 && ($g < $sx0 || $g > $sx1)} {
        m4stripe $::env(GND_NET) $NORMAL $g $cx0
        lappend export_ground [list $g $NORMAL]
    }
}

# SRAM-aligned M4 feeders
foreach x $wide_p {
    m4stripe $::env(VDD_NET) $WIDE $x $cx0
    lappend export_power [list $x $WIDE]
}
foreach x $wide_g {
    m4stripe $::env(GND_NET) $WIDE $x $cx0
    lappend export_ground [list $x $WIDE]
}
foreach x $narrow_p {
    m4stripe $::env(VDD_NET) $NARROW $x $cx0
    lappend export_power [list $x $NARROW]
}
foreach x $narrow_g {
    m4stripe $::env(GND_NET) $NARROW $x $cx0
    lappend export_ground [list $x $NARROW]
}

# Connect cells to PDN if needed (i.e. vias)
if {$::env(PDN_ENABLE_RAILS) == 1} {
    add_pdn_connect -grid stdcell_grid \
        -layers [list $::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)]
}


# Full-height, SRAM-aligned Metal4 stripes and matching fixed block pins.
# This runs before pdngen, but unlike add_pdn_stripe, dbSBox_create inserts
# physical metal directly rather than trimming it around a macro obstruction.
# The 24 X coordinates above were chosen to coincide with SRAM PG columns.
# Validate that these columns are actually safe in the full macro GDS.
set tech [ord::get_db_tech]
set m4 [$tech findLayer $::env(PDN_VERTICAL_LAYER)]
set vpwr [$block findNet $::env(VDD_NET)]
set vgnd [$block findNet $::env(GND_NET)]
if {$m4 == "NULL" || $vpwr == "NULL" || $vgnd == "NULL"} {
    utl::error PDN 901 "Cannot find vertical PDN layer or power nets."
}

# Use the existing core Y interval: in the supplied run it was 3.560..707.080um.
set cy0 [ord::dbu_to_microns [$cb yMin]]
set cy1 [ord::dbu_to_microns [$cb yMax]]

$vpwr setSpecial
$vgnd setSpecial
set psw [odb::dbSWire_create $vpwr ROUTED]
set gsw [odb::dbSWire_create $vgnd ROUTED]

# Physical wire only. The same rectangle will also be marked as a block pin.
proc fullheight_wire {sw layer x width y0 y1} {
    set half [expr {$width / 2.0}]
    odb::dbSBox_create $sw $layer \
        [ord::microns_to_dbu [expr {$x - $half}]] \
        [ord::microns_to_dbu $y0] \
        [ord::microns_to_dbu [expr {$x + $half}]] \
        [ord::microns_to_dbu $y1] STRIPE
}

foreach x $wide_p   { fullheight_wire $psw $m4 $x $WIDE   $cy0 $cy1 }
foreach x $wide_g   { fullheight_wire $gsw $m4 $x $WIDE   $cy0 $cy1 }
foreach x $narrow_p { fullheight_wire $psw $m4 $x $NARROW $cy0 $cy1 }
foreach x $narrow_g { fullheight_wire $gsw $m4 $x $NARROW $cy0 $cy1 }

# A dbBTerm is a named module connection; each dbBPin is an actual rectangle
# in that connection's pin definition. FIRM makes it survive pdngen, which
# otherwise deletes non-fixed existing pin shapes.
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
