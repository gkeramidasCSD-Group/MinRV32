-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   LIBRARY / USE  Imports definitions from external libraries. Every VHDL
--       file begins with these. 'ieee' is a standard library; 'work' refers
--       to the current design library (i.e. your own compiled units).
--
--   PACKAGE        A named container for shared declarations (types, constants,
--       functions). Other files say "use work.core_pkg.all" to import
--       everything declared here.
--
--   TYPE / SUBTYPE  VHDL is strongly typed. Custom enumeration types
--       (ALUControl_t, BranchOp_t, ...) let the compiler catch misconnected
--       signals at analysis time rather than at run time.
--
--   CONSTANT       Named compile-time values. Using MEM_BYTE instead of "00"
--       improves readability and prevents magic-number errors.
--
--   FUNCTION       A pure combinational computation. Functions defined in a
--       *package body* are available to every file that "use"s the package.
--
--   PACKAGE BODY   Holds the implementation of deferred (declared-only)
--       functions/procedures from the package header above.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Package: core_pkg
-- Shared type definitions and helper functions used throughout the repository
-- RTL. Each section below is grouped by the pipeline stage that consumes the
-- construct, with references to the RTL modules using it. Keeping the enums
-- centralized prevents the control/execute/memory blocks from diverging.
-- ============================================================================
package core_pkg is
  constant XLEN : natural := 32;

  subtype word_t is std_logic_vector(XLEN - 1 downto 0);
  subtype halfword_t is std_logic_vector(15 downto 0);
  subtype byte_t is std_logic_vector(7 downto 0);
  subtype byte_en_t is std_logic_vector(3 downto 0);

  -- ==========================================================================
  -- Execute stage ALU control (controller_pipe.vhd -> alu.vhd).
  -- `controller_pipe` writes the enum, `alu` decodes it in its case statement.
  -- ==========================================================================
  type ALUControl_t is (
    ALU_ADD,
    ALU_SUB,
    ALU_AND,
    ALU_OR,
    ALU_XOR,
    ALU_SLT,
    ALU_SLTU,
    ALU_SLL,
    ALU_SRL,
    ALU_SRA
  );

  -- ==========================================================================
  -- Branch/PC redirection (decode/control -> branch_unit.vhd + top-level wrapper).
  -- `branch_unit` evaluates the condition; the pipelined core selects the next PC.
  -- ==========================================================================
  type BranchOp_t is (
    BR_NONE,
    BR_EQ,
    BR_NE,
    BR_LT,
    BR_GE,
    BR_LTU,
    BR_GEU
  );

  -- ==========================================================================
  -- Operand selection feeding the ALU (datapath mux3 and mux2 instances).
  -- The datapath instantiates RS1/PC/zero + RS2/imm multiplexers using these.
  -- ==========================================================================
  type SrcASel_t is (
    OPA_RS1,
    OPA_PC,
    OPA_ZERO
  );

  type SrcBSel_t is (
    OPB_RS2,
    OPB_IMM
  );

  -- ==========================================================================
  -- Write-back stage multiplexer selection (mux3.vhd).
  -- Chooses between ALU, memory, and PC+4 for rd write-back.
  -- ==========================================================================
  type ResultSrc_t is (
    WB_ALU,
    WB_MEM,
    WB_PC4
  );

  -- ==========================================================================
  -- Immediate generation control for extend.vhd.
  -- ==========================================================================
  type ImmSrc_t is (
    IMM_I,
    IMM_S,
    IMM_B,
    IMM_U,
    IMM_J
  );

  -- ==========================================================================
  -- Memory stage sizing constants shared by controller_pipe.vhd, mem_access_unit.vhd,
  -- and the dmem.vhd model. Size field matches RV32I FUNCT3 encodings.
  -- ==========================================================================
  constant MEM_BYTE : std_logic_vector(1 downto 0) := "00";
  constant MEM_HALF : std_logic_vector(1 downto 0) := "01";
  constant MEM_WORD : std_logic_vector(1 downto 0) := "10";

  -- ==========================================================================
  -- Simulation helper shared by imem, dmem, regfile, and top.
  -- Guards against X/U/Z propagation in address vectors.
  -- ==========================================================================
  function addr_valid(addr_in : std_logic_vector) return boolean;

  -- Elaboration-time helper: returns true when n is an exact power of two.
  -- Used by imem/dmem to guard the WORDS generic at elaboration/synthesis.
  function is_power_of_two(n : positive) return boolean;

  -- Elaboration-time helper: ceiling of log2(n). log2_ceil(1) = 0,
  -- log2_ceil(2) = 1, log2_ceil(2048) = 11. Used to size address slices.
  function log2_ceil(n : positive) return natural;

end package core_pkg;

package body core_pkg is
  function addr_valid(addr_in : std_logic_vector) return boolean is
  begin
    for i in addr_in'range loop
      if addr_in(i) /= '0' and addr_in(i) /= '1' then
        return false;
      end if;
    end loop;
    return true;
  end function;

  function is_power_of_two(n : positive) return boolean is
    variable v : positive := n;
  begin
    while v > 1 loop
      if v mod 2 /= 0 then
        return false;
      end if;
      v := v / 2;
    end loop;
    return true;
  end function;

  function log2_ceil(n : positive) return natural is
    variable v : natural  := n - 1;
    variable r : natural  := 0;
  begin
    while v > 0 loop
      r := r + 1;
      v := v / 2;
    end loop;
    return r;
  end function;
end package body core_pkg;
