## Parser fixtures cover the GNU fallback formats seen by the real HAX-M1
## compiler gate. No process mocks: these are inputs to the pure text parser.
import std/[strutils, unittest]
import repro_hcr_linkgraph/type_layout

proc gnuLayout(typeName, memberName: string): string =
  """
 <0><c>: Abbrev Number: 1 (DW_TAG_compile_unit)
 <1><23>: Abbrev Number: 2 (DW_TAG_base_type)
    <24>   DW_AT_name        : int
    <26>   DW_AT_byte_size   : 4
 <1><62>: Abbrev Number: 6 (DW_TAG_structure_type)
    <63>   DW_AT_name        : $1
    <64>   DW_AT_byte_size   : 8
 <2><67>: Abbrev Number: 7 (DW_TAG_member)
    <68>   DW_AT_name        : $2
    <69>   DW_AT_type        : <0x23>
    <6f>   DW_AT_data_member_location: 4
""" % [typeName, memberName]

suite "HCR GNU DWARF attributes":
  test "indexed strings preserve only the resolved names":
    let layouts = extractTypeLayoutsFromDwarf(gnuLayout(
      "(indexed string: 0xb): Vector3D", "(indexed string: 0x7): x"))
    require layouts.len == 1
    check layouts[0].name == "Vector3D"
    check layouts[0].byteSize == 8
    require layouts[0].members.len == 1
    check layouts[0].members[0].name == "x"
    check layouts[0].members[0].offsetBytes == 4

  test "indirect strings preserve namespace separators":
    let layouts = extractTypeLayoutsFromDwarf(gnuLayout(
      "(indirect string, offset: 0x31): geometry::Vector3D",
      "(indirect string, offset: 0x42): coordinate"))
    require layouts.len == 1
    check layouts[0].name == "geometry::Vector3D"
    require layouts[0].members.len == 1
    check layouts[0].members[0].name == "coordinate"

  test "inline GNU names are not stripped at a colon":
    let layouts = extractTypeLayoutsFromDwarf(gnuLayout("geometry::Vector3D", "x"))
    require layouts.len == 1
    check layouts[0].name == "geometry::Vector3D"
    require layouts[0].members.len == 1
    check layouts[0].members[0].name == "x"

  test "angle bracket references resolve the member type":
    let layouts = extractTypeLayoutsFromDwarf(gnuLayout("Vector3D", "x"))
    require layouts.len == 1
    require layouts[0].members.len == 1
    check layouts[0].members[0].typeName == "int"

  test "angle bracket references resolve anonymous typedef names":
    let dump = """
 <0><c>: Abbrev Number: 1 (DW_TAG_compile_unit)
 <1><23>: Abbrev Number: 2 (DW_TAG_typedef)
    <24>   DW_AT_name        : (indexed string: 0x2): Vector3D
    <25>   DW_AT_type        : <0x62>
 <1><62>: Abbrev Number: 6 (DW_TAG_structure_type)
    <64>   DW_AT_byte_size   : 16
"""
    let layouts = extractTypeLayoutsFromDwarf(dump)
    require layouts.len == 1
    check layouts[0].name == "Vector3D"
    check layouts[0].byteSize == 16

  test "dwarfdump quoted names and hexadecimal offsets remain supported":
    let dump = """
0x0000000b: DW_TAG_compile_unit
0x00000026:   DW_TAG_structure_type
                DW_AT_name ("geometry::Vector3D")
                DW_AT_byte_size (0x10)
0x0000002f:     DW_TAG_member
                  DW_AT_name ("x")
                  DW_AT_type (0x00000050 "int")
                  DW_AT_data_member_location (0x04)
0x00000040:     NULL
"""
    let layouts = extractTypeLayoutsFromDwarf(dump)
    require layouts.len == 1
    check layouts[0].name == "geometry::Vector3D"
    check layouts[0].byteSize == 16
    require layouts[0].members.len == 1
    check layouts[0].members[0].name == "x"
    check layouts[0].members[0].typeName == "int"
    check layouts[0].members[0].offsetBytes == 4
